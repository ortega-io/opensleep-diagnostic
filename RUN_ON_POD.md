# Running opensleep-diagnostic on the Pod 3 Hub

This tool is a diagnostic, not a service. It runs once, prints/writes a summary, and exits. Do
not install it as a systemd unit.

The target Hub is assumed to be: not connected to the mattress cover, not filled with water, and
therefore not safe for any pump, TEC, heating/cooling, vibration, alarm, or priming operation.
`opensleep-diagnostic` cannot transmit any of those regardless (see `SAFETY.md`), but the deploy
steps below still assume that context.

## 1. Copy the binary to the Pod

From your build host, after `./build.sh` has produced `dist/opensleep-diagnostic-aarch64-static`:

```sh
scp dist/opensleep-diagnostic-aarch64-static \
    root@POD_IP:/persistent/tools/opensleep-diagnostic
```

## 2. Make it executable and sanity-check the artifact on-device

```sh
chmod 755 /persistent/tools/opensleep-diagnostic
file /persistent/tools/opensleep-diagnostic
```

`file` should report an AArch64, statically linked ELF binary, matching `build-report.txt`.

## 3. Stop stock services that might own the UART or I2C devices

Stock `capybara`/`frank`/`frankenfirmware`/`dac` may hold `/dev/ttyS1`, `/dev/ttyS2`, or
`/dev/i2c-1` open, which would make this diagnostic's opens fail or race with stock traffic.
Stop them first:

```sh
systemctl stop capybara.service 2>/dev/null || true
systemctl stop frank.service 2>/dev/null || true
systemctl stop frankenfirmware.service 2>/dev/null || true
systemctl stop dac.service 2>/dev/null || true
```

These `|| true` guards mean it's fine if a given unit doesn't exist on this build.

## 4. First run: passive only (no reset, no firmware jump)

```sh
RUST_LOG=debug \
/persistent/tools/opensleep-diagnostic \
    --i2c-device /dev/i2c-1 \
    --frozen-port /dev/ttyS1 \
    --sensor-port /dev/ttyS2 \
    --timeout-seconds 3 \
    --json-output /persistent/opensleep-diagnostic-passive.json \
    --verbose \
    2>&1 | tee /persistent/opensleep-diagnostic-passive.log
```

Expected on this hardware revision: the `0x20` reset/enable expander probe should succeed, and
the `0x53` LED controller probe should fail with `ENXIO` and be logged as "LED controller
unavailable; continuing diagnostic" — this is expected and does not fail the run. Review
`Frozen Ping response` and `Sensor detected mode`/`Sensor Ping response` in the summary (or the
JSON file) to see whether either MCU answered without any reset.

## 5. Review the first run before doing anything else

Read `/persistent/opensleep-diagnostic-passive.log` (or the JSON) before proceeding. In
particular check:

* `I2C bus open` and `Reset expander 0x20 probe` — if either failed, something more fundamental
  than "the subsystems need a reset" is wrong (wrong I2C bus path, permissions, hardware fault),
  and running the reset sequence is unlikely to help.
* Whether Frozen/Sensor already answered without a reset. If they did, you likely don't need
  step 6 at all for this session.

## 6. Second run: only after reviewing the first, may include the known reset sequence

Whenever `--reset-subsystems` is used, Sensor is tested **before** Frozen by default (this is
`--sensor-first`'s default, tied to `--reset-subsystems`; see below), and immediately after the
reset-expander sequence releases, Sensor's bootloader baud is probed with repeated `Ping`s rather
than a single one several seconds later. This is specifically to catch a short post-reset
bootloader-listening window that a Frozen-first, single-Ping approach could miss.

```sh
RUST_LOG=debug \
/persistent/tools/opensleep-diagnostic \
    --i2c-device /dev/i2c-1 \
    --frozen-port /dev/ttyS1 \
    --sensor-port /dev/ttyS2 \
    --timeout-seconds 5 \
    --reset-subsystems \
    --sensor-first \
    --sensor-bootloader-probe-ms 3000 \
    --sensor-bootloader-interval-ms 100 \
    --skip-frozen-firmware \
    --json-output /persistent/opensleep-diagnostic-sensor-first.json \
    --verbose \
    2>&1 | tee /persistent/opensleep-diagnostic-sensor-first.log
```

* `--reset-subsystems` runs exactly the four fixed register writes to `0x20` documented in
  `SAFETY.md` (mirroring `opensleep::reset::ResetController`'s existing sequence) and nothing
  else.
* `--sensor-first` is already the default here since `--reset-subsystems` is present; it's passed
  explicitly for clarity. Pass `--sensor-first=false` if you specifically want the old
  Frozen-first ordering even with a reset.
* `--sensor-bootloader-probe-ms`/`--sensor-bootloader-interval-ms` control how long and how often
  Sensor's bootloader baud is re-pinged immediately after reset (defaults: retry every 100ms for
  3000ms, or until a valid response, whichever comes first).
* `--skip-frozen-firmware` (also already the default) keeps Frozen's optional `GetFirmware` step
  out of this run entirely, since a slow/absent response to it was previously delaying the whole
  Frozen phase behind a timeout for no diagnostic benefit. Pass `--skip-frozen-firmware=false` if
  you specifically want that step back.

Do **not** add `--allow-firmware-jump` to these first two runs. Only consider it, deliberately
and separately, once you've reviewed both logs above and specifically want to test whether a
subsystem found in its bootloader can be transitioned to firmware. Even with that flag, this tool
never follows a firmware jump with any temperature, pump, priming, vibration, alarm, or piezo
command — see `SAFETY.md`.

### Reading the new Sensor bootloader-probe fields

The text summary and JSON output (from this run) include, in addition to the fields already
described below:

| Field | Meaning |
|---|---|
| `Sensor tested first after reset` | Whether Sensor was probed before Frozen this run |
| `Sensor bootloader probe duration` | The configured `--sensor-bootloader-probe-ms` window |
| `Sensor bootloader Ping attempts` | How many `Ping`s were actually sent during that window |
| `Sensor bootloader bytes received` | Total raw bytes read back, even if none of them decoded |
| `Sensor bootloader valid response` | PASS if at least one frame decoded successfully (not necessarily a Pong) |
| `Sensor bootloader decode errors` | Count of byte spans discarded while scanning for a valid frame (bad checksum, bad structure, or noise) -- distinct from simply receiving nothing |
| `Sensor first byte latency after reset` | Time from reset release to the first byte of any kind received on the Sensor UART |
| `Sensor first valid frame latency` | Time from reset release to the first successfully decoded Sensor frame |
| `Sensor firmware Ping response` | PASS/FAIL for the firmware-baud attempt specifically (run after the bootloader probe, regardless of its outcome) |

If `Sensor bootloader bytes received` is nonzero but `Sensor bootloader valid response` is FAIL,
something is reaching the UART (wrong baud, noise, a different protocol) but not decoding as an
OpenSleep Sensor frame -- worth investigating before assuming the MCU is simply absent.

## Interpreting the exit code

| Code | Meaning |
|---|---|
| 0 | Both Sensor and Frozen responded to Ping |
| 10 | Frozen did not respond, Sensor did |
| 11 | Sensor did not respond, Frozen did |
| 12 | Neither subsystem responded |
| 20 | I2C bus failed to open, the `0x20` reset expander did not answer, or a requested reset write failed (UART tests still ran and are reported; the missing `0x53` LED controller never causes this code) |
| 30 | Invalid CLI arguments or a local program error (nothing was probed) |

## What this tool will never do on the Pod

See `SAFETY.md` for the full accounting. In short: it never loads `config.ron`, never connects to
MQTT, never runs the Home Assistant integration, never starts a profile or temperature schedule,
never writes to `0x53`, and never transmits a pump/heater/cooler/vibration/alarm/piezo/calibration
command. It always exits after one pass.
