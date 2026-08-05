# Running opensleep-diagnostic on the Pod 3 Hub

This tool is a diagnostic, not a service. Every subcommand runs once, in the foreground, prints/
writes a summary, and exits. **Do not install it as a systemd unit.** Priming is always manually
initiated, every time — this tool never schedules or repeats it automatically.

Four subcommands:

* `opensleep-diagnostic frozen-passive` — safe with the cover disconnected and no water.
* `opensleep-diagnostic frozen-prime-test` — intentionally sends `Prime` once, to fill an empty or
  partially-filled hydraulic loop; requires a connected cover with water in the reservoir and
  multiple explicit confirmations. **Read SAFETY.md before running this.**
* `opensleep-diagnostic frozen-cool-test` — intentionally activates one cooling channel; requires
  a connected, *already-filled* hydraulic loop and multiple explicit confirmations. **Read
  SAFETY.md before running this.**
* `opensleep-diagnostic emergency-stop` — independent fast-path disable + reset-assert.

## 1. Copy the binary to the Pod

From your build host:

```sh
scp dist/opensleep-diagnostic-aarch64-static \
    root@POD_IP:/persistent/tools/opensleep-diagnostic
```

Or, if the Hub has outbound network access, download it directly from the GitHub Release instead
of scp'ing from a build host (keep the filename matching the `.sha256` file until after
verification, then move it into place):

```sh
cd /tmp
curl -L -O https://github.com/ortega-io/opensleep-diagnostic/releases/download/diagnostic-v5/opensleep-diagnostic-aarch64-static
curl -L -O https://github.com/ortega-io/opensleep-diagnostic/releases/download/diagnostic-v5/opensleep-diagnostic-aarch64-static.sha256
sha256sum -c opensleep-diagnostic-aarch64-static.sha256
mv opensleep-diagnostic-aarch64-static /persistent/tools/opensleep-diagnostic
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
systemctl stop opensleep-manual-ui.service 2>/dev/null || true
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

Do **not** proceed until you've reviewed this output. If Frozen never reached application
firmware, or no telemetry decoded, something more fundamental needs investigating first — priming
or cooling are unlikely to help and are not safe to attempt yet regardless.

### Exit codes (`frozen-passive`)

| Code | Meaning |
|---|---|
| 0 | Application firmware responded and at least one valid telemetry sample decoded, and safe-stop fully succeeded |
| 10 | Frozen was detected in its bootloader and never reached application firmware |
| 11 | Frozen did not respond at all, or telemetry never validated |
| 20 | I2C bus failed to open |
| 30 | Invalid CLI arguments (nothing was probed) |
| 40 | Refused: a stock service was active, or a device was already open elsewhere |

## 5. Only after reviewing valid passive telemetry: prepare the hydraulic loop

Do this only once you've confirmed, from step 4's output, that Frozen reaches application
firmware and reports valid telemetry.

1. **Connect both hydraulic lines** from the cover to the Hub.
2. **Fill the reservoir** with water.
3. **Keep additional water ready** nearby — priming may draw down the reservoir level quickly and
   you may need to top it up.
4. **Check for visible leaks** at every fitting and hose run before proceeding.
5. **Open a second SSH session** to the Hub and have this ready to run immediately, but do not run
   it yet:
   ```sh
   /persistent/tools/opensleep-diagnostic emergency-stop
   ```
6. Read SAFETY.md in full if you have not already.

## 6. If the loop is empty or partially filled: run a supervised priming cycle first

**Skip this step only if you already know the hydraulic loop is fully filled and water has
previously circulated through it.** If in doubt, run this step — `frozen-prime-test` is the
correct way to fill an empty loop, not `frozen-cool-test`.

```sh
/persistent/tools/opensleep-diagnostic frozen-prime-test \
    --i2c-device /dev/i2c-1 \
    --frozen-port /dev/ttyS1 \
    --duration-seconds 30 \
    --confirm-cover-hydraulics-connected \
    --confirm-reservoir-filled \
    --confirm-cover-loop-needs-priming \
    --confirm-no-visible-leaks \
    --confirm-active-test \
    --json-output /persistent/frozen-prime.json \
    --verbose
```

You will be asked to type, exactly:

```
I CONFIRM THE RESERVOIR IS FILLED AND THE COVER IS CONNECTED
```

The tool will then run preflight (reset, enter firmware, disable both sides, confirm neither is
enabled, collect fresh baseline telemetry), print a warning, and ask for a second exact phrase:

```
START SUPERVISED PRIMING
```

7. **Watch the reservoir continuously** for the entire run. The firmware does not reliably report
   the reservoir level on this hardware (`capwater` has been observed unavailable) — this tool
   cannot detect an empty reservoir on your behalf.
8. **Press Ctrl+C immediately** if the reservoir approaches empty, or if you observe a leak, a
   burning smell, or abnormal noise. This runs the same safe-stop sequence (disable both sides
   three times, flush UART, assert the `0x20` subsystem reset) as every other exit path.

   `emergency-stop` from your second session works the same way if this session becomes
   unresponsive.

This one 30-second (default; 5-60s range) run sends `Prime` **exactly once**, watches decoded
telemetry and firmware messages the whole time, and stops early — running the same safe-stop — the
moment firmware reports priming complete. It never repeats or retries automatically.

9. **Refill the reservoir** after the cycle, since priming likely drew it down.
10. **Inspect for leaks** again before doing anything further.
11. **Run another separate priming cycle only if needed** — e.g. if the loop still isn't fully
    primed, or you had to stop early. Each invocation is independent; there is no "resume."
12. **Do not proceed to step 7 (cooling) until you have observed water movement and the reservoir
    level has stabilized** (stopped dropping between refills). Read the JSON/printed summary's
    `prime_results` block — see "Reading the priming result" below — before deciding whether
    another cycle is needed.

### Reading the priming result

```
Frozen application firmware:       PASS/FAIL
Prime command transmitted:         PASS/FAIL
Prime acknowledgment:              PASS/FAIL/UNVERIFIED
Prime start observed:              PASS/FAIL/UNVERIFIED
Left pump telemetry:               PASS/FAIL/UNVERIFIED
Right pump telemetry:              PASS/FAIL/UNVERIFIED
Left pump operator observation:    PASS/FAIL/UNVERIFIED
Right pump operator observation:   PASS/FAIL/UNVERIFIED
Solenoid operation:                PASS/FAIL/UNVERIFIED
Water movement observed:           PASS/FAIL/UNVERIFIED
Prime completion observed:         PASS/FAIL/UNVERIFIED
Safe-stop and reset:               PASS/FAIL
Overall result:                    PASS/FAIL/INCONCLUSIVE
```

At the end you'll be prompted for operator observations (left/right pump heard/felt, water
movement or bubbles observed, reservoir level dropped, reservoir topped up, leak, abnormal noise,
burning smell, free-text notes) — stored separately from the machine-decoded evidence in the JSON
report's `prime_operator_observations` field.

**`Overall result` will not read PASS merely because the command was sent, acknowledged, a pump
showed voltage, or "priming done" was printed.** It only reads PASS with either direct firmware
evidence of water circulation, or your own confirmation of *both* water movement *and* a dropped
reservoir level. If everything ran but circulation wasn't clearly observed, expect
**INCONCLUSIVE**, not PASS — see PROTOCOL_AUDIT.md for exactly why. An INCONCLUSIVE or FAIL result
means: inspect, refill, and consider another cycle before moving on to cooling.

## 7. Once the loop is confirmed filled: run a 10-second cooling test on one side

Only proceed here once you've confirmed water movement and a stable reservoir level from step 6
(or already knew the loop was filled and skipped step 6).

`--delta-c 1.0` and `--duration-seconds 10` are both already the defaults for a first test; they're
spelled out below for clarity. Only the selected side is ever enabled -- the other side is
explicitly disabled before the test starts and stays that way for the whole run.

```sh
/persistent/tools/opensleep-diagnostic frozen-cool-test \
    --side left \
    --delta-c 1.0 \
    --duration-seconds 10 \
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

If you observe any of the last three, **type `ABORT` (or a word like `LEAK`) and press Enter**, or
press **Ctrl+C** immediately, or run `emergency-stop` from your second session -- all three stop
the test the same way. The tool itself also aborts automatically on: lost/stale telemetry (> 2s), a
UART read/write failure, an implausible temperature jump, the heatsink or water-temperature limits
being exceeded, the selected pump still reporting off/0V more than 3 seconds after being enabled,
a firmware message reporting the selected TEC locked, Frozen disabling the selected side on its
own, a firmware fault-keyword message after a brief startup grace period, or the (non-overridable,
30-second-max) duration expiring -- see SAFETY.md for the full list. It always runs the same
safe-stop sequence regardless of why it stopped.

At the end, you'll be prompted for operator observations (pump heard/felt, fan seen/heard, airflow
felt, leak observed, unusual smell/noise, free-text notes). These are stored in the JSON report as
`operator_observations`, kept separate from the machine-decoded `telemetry_samples` and
`outgoing_commands`.

Only test one side per invocation. Repeat with `--side right` as a separate run if desired.

### Reading the cooling result

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
opensleep-diagnostic frozen-prime-test --dry-run \
    --confirm-cover-hydraulics-connected --confirm-reservoir-filled \
    --confirm-cover-loop-needs-priming --confirm-no-visible-leaks --confirm-active-test \
    --json-output /tmp/dryrun-prime.json
opensleep-diagnostic frozen-cool-test --side left --dry-run \
    --confirm-cover-hydraulics-connected --confirm-water-loop-filled \
    --confirm-no-visible-leaks --confirm-active-test \
    --json-output /tmp/dryrun-cool.json
opensleep-diagnostic emergency-stop --dry-run
```

`frozen-prime-test --dry-run` and `frozen-cool-test --dry-run` still require the interactive typed
confirmations unless stdin is not a TTY (e.g. when piping input in a script or CI). Dry-run never
silently switches to live mode — if it can't run against the mock, it refuses, the same as live
mode would.

## What this tool will never do on the Pod

See SAFETY.md and PROTOCOL_AUDIT.md for the full accounting. In short: it never loads the normal
config file, never connects to MQTT, never runs the Home Assistant integration, never starts a
profile or temperature schedule outside its own bounded active phase, never writes to `0x53`, and
never transmits `Prime` outside `frozen-prime-test` (where it is sent at most once per invocation,
always manually confirmed, never scheduled or repeated automatically) or an arbitrary/undocumented
command. It always exits after one bounded pass and is never installed as a service.
