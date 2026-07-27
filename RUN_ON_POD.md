# Running opensleep-diagnostic on the Pod 3 Hub

This tool is a diagnostic, not a service. Every subcommand runs once, in the foreground, prints/
writes a summary, and exits. **Do not install it as a systemd unit.**

Three subcommands:

* `opensleep-diagnostic frozen-passive` — safe with the cover disconnected and no water.
* `opensleep-diagnostic frozen-cool-test` — intentionally activates one cooling channel; requires
  a connected, filled hydraulic loop and multiple explicit confirmations. **Read SAFETY.md before
  running this.**
* `opensleep-diagnostic emergency-stop` — independent fast-path disable + reset-assert.

## 1. Copy the binary to the Pod

```sh
scp dist/opensleep-diagnostic-aarch64-static \
    root@POD_IP:/persistent/tools/opensleep-diagnostic
```

## 2. Make it executable and sanity-check it on-device

```sh
chmod 755 /persistent/tools/opensleep-diagnostic
file /persistent/tools/opensleep-diagnostic
```

`file` should report an AArch64, statically linked ELF binary with no dynamic interpreter,
matching `build-report.txt`.

## 3. Stop stock services that might own the UART or I2C devices

```sh
systemctl stop capybara.service 2>/dev/null || true
systemctl stop dac.service 2>/dev/null || true
systemctl stop frank.service 2>/dev/null || true
systemctl stop frankenfirmware.service 2>/dev/null || true
systemctl stop opensleep.service 2>/dev/null || true
```

Then confirm nothing still holds the devices open:

```sh
fuser -v /dev/i2c-1 /dev/ttyS1
```

`opensleep-diagnostic` also performs this check itself before touching either device (best-effort
`systemctl is-active` + a `/proc/*/fd` scan) and refuses to run if it detects a stock service still
active or either device already open elsewhere.

## 4. First run: `frozen-passive`, with the cover still disconnected

```sh
/persistent/tools/opensleep-diagnostic frozen-passive \
    --i2c-device /dev/i2c-1 \
    --frozen-port /dev/ttyS1 \
    --reset-subsystems \
    --allow-firmware-jump \
    --duration-seconds 15 \
    --json-output /persistent/frozen-passive.json \
    --csv-output /persistent/frozen-passive.csv \
    --verbose
```

Expected on this hardware revision: the `0x20` reset/enable expander probe succeeds, and the
`0x53` LED controller probe fails with ENXIO and is logged as expected/nonfatal. Review the
printed summary (or the JSON file) for:

* `frozen_bootloader_ping` / `frozen_firmware_ping` — which mode Frozen was in, and whether it
  answered.
* `frozen_hardware_info` — the decoded hardware info string.
* `telemetry_samples` — every decoded temperature sample, with the solicited/unsolicited source
  tag.
* `overall_pass` — only `true` if application firmware responded and at least one valid telemetry
  sample was decoded.

Do **not** proceed to step 5 until you've reviewed this output. If Frozen never reached
application firmware, or no telemetry decoded, something more fundamental needs investigating
first — running the cooling test is unlikely to help and is not safe to attempt yet regardless
(see below).

### Exit codes (`frozen-passive`)

| Code | Meaning |
|---|---|
| 0 | Application firmware responded and at least one valid telemetry sample decoded, and safe-stop fully succeeded |
| 10 | Frozen was detected in its bootloader and never reached application firmware |
| 11 | Frozen did not respond at all, or telemetry never validated |
| 20 | I2C bus failed to open |
| 30 | Invalid CLI arguments (nothing was probed) |
| 40 | Refused: a stock service was active, or a device was already open elsewhere |

## 5. Only after reviewing valid passive telemetry: prepare for `frozen-cool-test`

Do this only once you've confirmed, from step 4's output, that Frozen reaches application
firmware and reports valid telemetry.

1. Connect the hydraulic cover to the Hub.
2. Fill the water loop per the normal Eight Sleep fill procedure.
3. Visually check every visible fitting and hose run for leaks before proceeding.
4. **Open a second SSH session** to the Hub and have this ready to run immediately, but do not run
   it yet:
   ```sh
   /persistent/tools/opensleep-diagnostic emergency-stop
   ```
5. Read SAFETY.md in full if you have not already.

## 6. Run a 15-second cooling test on one side

```sh
/persistent/tools/opensleep-diagnostic frozen-cool-test \
    --side left \
    --delta-c 1.0 \
    --duration-seconds 15 \
    --confirm-cover-hydraulics-connected \
    --confirm-water-loop-filled \
    --confirm-no-visible-leaks \
    --confirm-active-test \
    --json-output /persistent/frozen-cool-left.json \
    --csv-output /persistent/frozen-cool-left.csv \
    --verbose
```

You will be asked to type, exactly:

```
I CONFIRM THE WATER LOOP IS CONNECTED AND FILLED
```

The tool will then run preflight (reset, enter firmware, collect >= 5 baseline samples over >= 5
seconds, validate the baseline is within 15–35C and internally consistent), print the proposed
target, and ask for a second exact phrase:

```
START LEFT COOLING TEST
```

During the active phase, watch/listen (without touching or metering the open board) for:

* Pump sound or vibration
* Fan movement or airflow
* Unexpected noise
* Leaks
* A burning smell

If you observe any of the last three, press **Ctrl+C** immediately, or run `emergency-stop` from
your second session. The tool itself also aborts automatically on: lost/stale telemetry (> 2s),
a UART read/write failure, an implausible temperature jump, the heatsink or water-temperature
limits being exceeded, or the (non-overridable, 30-second-max) duration expiring — and always runs
the same safe-stop sequence regardless of why it stopped.

At the end, you'll be prompted for operator observations (pump heard/felt, fan seen/heard, airflow
felt, leak observed, unusual smell/noise, free-text notes). These are stored in the JSON report as
`operator_observations`, kept separate from the machine-decoded `telemetry_samples` and
`outgoing_commands`.

Only test one side per invocation. Repeat with `--side right` as a separate run if desired.

### Reading the result

The JSON/text summary reports each component separately — never collapses them into one
pass/fail:

```
Frozen command accepted:        PASS/FAIL/UNKNOWN
Pump operation:                 PASS/FAIL/UNVERIFIED
Fan operation:                  PASS/FAIL/UNVERIFIED
TEC cooling operation:          PASS/FAIL/UNVERIFIED
Telemetry remained valid:       PASS/FAIL
Emergency shutdown:             PASS/FAIL
Overall selected-side result:   PASS/FAIL/INCONCLUSIVE
```

See PROTOCOL_AUDIT.md for exactly what evidence can ever produce a PASS for each line — in
particular, pump/fan/TEC are never marked PASS merely because the command was accepted.

## Dry-run mode (safe on any development machine, no hardware needed)

Every subcommand accepts `--dry-run`, which performs no I2C or UART writes at all and instead runs
the same logic against a mocked Frozen device and a mocked I2C bus:

```sh
opensleep-diagnostic frozen-passive --dry-run --json-output /tmp/dryrun-passive.json
opensleep-diagnostic frozen-cool-test --side left --dry-run \
    --confirm-cover-hydraulics-connected --confirm-water-loop-filled \
    --confirm-no-visible-leaks --confirm-active-test \
    --json-output /tmp/dryrun-cool.json
opensleep-diagnostic emergency-stop --dry-run
```

`frozen-cool-test --dry-run` still requires the interactive typed confirmations unless stdin is
not a TTY (e.g. when piping input in a script or CI).

## What this tool will never do on the Pod

See SAFETY.md and PROTOCOL_AUDIT.md for the full accounting. In short: it never loads
`config.ron`, never connects to MQTT, never runs the Home Assistant integration, never starts a
profile or temperature schedule outside its own bounded active phase, never writes to `0x53`, and
never transmits `Prime` or an arbitrary/undocumented command. It always exits after one bounded
pass and is never installed as a service.
