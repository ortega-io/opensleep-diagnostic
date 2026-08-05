# Running opensleep-diagnostic on the Pod 3 Hub

This tool is a diagnostic, not a service. Every subcommand runs once, in the foreground, prints/
writes a summary, and exits. **Do not install it as a systemd unit.** Priming is always manually
initiated, every time — this tool never schedules or repeats it automatically.

Five subcommands:

* `opensleep-diagnostic frozen-passive` — safe with the cover disconnected and no water.
* `opensleep-diagnostic frozen-prime-test` — intentionally sends `Prime` once, to fill an empty or
  partially-filled hydraulic loop, via this binary's own reimplemented reset/transport; requires a
  connected cover with water in the reservoir and multiple explicit confirmations. **Read
  SAFETY.md before running this.**
* `opensleep-diagnostic frozen-prime-opensleep-init` — the same Prime-once operation, but through
  the real, unmodified upstream OpenSleep initialization and Frozen manager code instead. **Read
  SAFETY.md before running this.** Add `--release-frozen-only` for a third, narrower startup mode
  that releases Frozen from reset with a single-bit I2C write instead of the full upstream reset
  sequence — see that flag's own section below and in SAFETY.md.
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
curl -L -O https://github.com/ortega-io/opensleep-diagnostic/releases/download/diagnostic-v8/opensleep-diagnostic-aarch64-static
curl -L -O https://github.com/ortega-io/opensleep-diagnostic/releases/download/diagnostic-v8/opensleep-diagnostic-aarch64-static.sha256
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

### `frozen-prime-opensleep-init`: the same priming, through real OpenSleep initialization

Use this subcommand instead of `frozen-prime-test` if you want the fill/priming operation run
through the real, unmodified upstream OpenSleep initialization and Frozen manager code -- e.g.
`frozen-prime-test` reported `[capwater]`/`[flowrate]` unavailable and you want to rule out this
binary's own reimplemented reset/transport as the cause. This is a different safety model, not a
relaxed one — read this whole section before using it. See SAFETY.md for the full writeup.

```sh
/persistent/tools/opensleep-diagnostic frozen-prime-opensleep-init \
    --confirm-cover-hydraulics-connected \
    --confirm-reservoir-filled \
    --confirm-cover-loop-needs-priming \
    --confirm-no-visible-leaks \
    --confirm-active-test \
    --json-output /persistent/frozen-prime-opensleep-init.json \
    --verbose
```

You'll be asked for the same two typed confirmation phrases as `frozen-prime-test`. There is no
`--i2c-device`/`--frozen-port` flag: I2C is always `/dev/i2c-1`, and Frozen's UART is always
`/dev/ttyS1` -- confirmed correct for this Hub (a live run failed with `Serial Io(NotFound)` when
the upstream `opensleep::frozen::PORT` default, `/dev/ttymxc2`, correct only for the MT8365 devkit
the pinned upstream source targets, was used instead). A preflight check refuses to proceed --
before touching I2C at all -- if `/dev/ttyS1` does not exist.

* This mode runs the **real** `opensleep::reset::ResetController::reset_subsystems` (not this
  binary's own reimplementation), the real LED controller, a real (never-connected) MQTT client,
  and — doing all of the actual work — the real `opensleep::frozen::run` manager, called with
  `/dev/ttyS1` explicitly (never the upstream default). It never reads your saved `config.ron`; it
  builds its own in-memory configuration with temperature profiles disabled. **It never starts the
  Sensor subsystem at all** -- Sensor is a separate physical UART with no bearing on Frozen priming,
  so the surest way to guarantee it can't block priming is to never run it.
* Frozen must already be running application firmware, or already reachable from its bootloader
  through the real wake sequence; if it never answers `Pong(true)`, the tool refuses to send Prime.
* **If firmware reports `[capwater] sensor unavailable` as a result of this run's own
  initialization, `Prime` is never sent.** The tool prints what happened during initialization so
  you can diagnose it.
* The observation window is fixed at the firmware-reported priming duration (600000 ms) and is not
  configurable.
* **There is no routine I2C subsystem-reset backstop in this mode.** On exit — normal completion,
  `"done because empty"`, the window elapsing, or a stop signal — this mode does not assert the I2C
  reset; Frozen's firmware returns to idle on its own. The one exception is a genuine
  firmware-reported pump fault, which does trigger an emergency reset. **If priming does not
  visibly stop, reboot the Hub or disconnect Hub power yourself.** Keep that access ready for the
  whole run, same as always.
* Temperature targets are never enabled during this run, so there is nothing to actively disable at
  shutdown.
* The printed/JSON summary reports this mode's own result block instead of `prime_results`:

  ```
  Subsystem reset performed/ok:    true/true
  Device label:                    <whatever /home/dac/app/sewer/device-label contains, or "unknown">
  Frozen UART requested:           /dev/ttyS1
  Frozen UART opened:              true/false
  Frozen manager task running:     true/false
  Frozen reached firmware:         true/false
  [capwater] unavailable observed: true/false
  [flowrate] unavailable observed: true/false
  Prime outcome:                   success / incomplete (done because empty) / not observed within window / not sent
  Prime sent:                      true/false
  Prime sent count:                0 or 1
  Normal done observed:            true/false
  Done because empty observed:     true/false
  Emergency reset asserted:        true/false
  ```

  `Frozen UART opened` is inferred, not directly reported by the real manager: this mode watches
  whether the manager's task is still running ~500ms after starting (a real open failure like
  `Serial Io(NotFound)` resolves near-instantly) rather than reporting merely that a task was
  spawned.

`--dry-run` for this mode only validates confirmations/arguments — unlike this binary's other
`--dry-run` modes, it cannot run the real upstream code against a mock, because that code hardcodes
real serial ports and I2C devices and has no mock transport to substitute one into.

### `--release-frozen-only`: minimal startup, no global reset

Add `--release-frozen-only` to `frozen-prime-opensleep-init` when you specifically want to release
Frozen from reset **without** running the full upstream I2C reset sequence and **without** the
earlier `--preserve-boot-state` flag (removed; this flag replaces it). Real hardware evidence: the
full reset does release Frozen, but it also reconfigures I2C expander registers `0x06`/`0x07` and
leaves the reservoir-fill indicator off and unresponsive afterward. This mode instead flips only
bit 1 of register `0x02` (`released = original & !0x02`), verifies the readback, and never touches
`0x06`/`0x07` at all. **Read the `--release-frozen-only` section of SAFETY.md before using this —
it is a third, narrower safety model, not a relaxed one.**

```sh
/persistent/tools/opensleep-diagnostic frozen-prime-opensleep-init \
    --release-frozen-only \
    --confirm-cover-hydraulics-connected \
    --confirm-reservoir-filled \
    --confirm-cover-loop-needs-priming \
    --confirm-no-visible-leaks \
    --confirm-active-test \
    --json-output /persistent/frozen-release-frozen-only.json \
    --verbose
```

You'll be prompted for the same two typed phrases as plain `frozen-prime-opensleep-init`, and then
— immediately before `Prime` is sent, once Frozen has reached application firmware and startup
messages have been observed — a **third** phrase:

```
Type RESERVOIR INDICATOR IS STILL WORKING to continue:
```

Only type this if the reservoir-fill indicator is genuinely still responding after Frozen was
released. This mode's own report includes a
`reservoir_sensor_operational_after_release` field recording what was actually observed.

* On normal completion (`"done"` or `"done because empty"`), this mode performs **no I2C write at
  all** on exit — it does not restore register `0x02` and does not run any reset. Frozen is left
  released and running. If priming does not visibly stop, reboot the Hub or disconnect Hub power.
* The only exception is a genuine firmware-reported pump fault, which re-asserts bit 1 of register
  `0x02` only (never the full four-register reset, never `0x06`/`0x07`).
* Unlike plain `frozen-prime-opensleep-init --dry-run` above, `--release-frozen-only --dry-run`
  *can* run end to end against a mocked I2C expander and a mocked Frozen device — it never calls
  into code that hardcodes real serial ports or I2C devices:

  ```sh
  opensleep-diagnostic frozen-prime-opensleep-init --release-frozen-only --dry-run \
      --confirm-cover-hydraulics-connected --confirm-reservoir-filled \
      --confirm-cover-loop-needs-priming --confirm-no-visible-leaks --confirm-active-test \
      --json-output /tmp/dryrun-release-frozen-only.json
  ```

* The printed/JSON summary reports its own result block instead of `opensleep_init_results`:

  ```
  Register 0x02: original=0b11111111 released=0b11111101 changed_mask=0b00000010 readback=0b11111101
  Readback matches / only bit 1 changed: true/true
  Frozen UART opened:              true/false
  Frozen reached firmware:         true/false
  [capwater] unavailable observed: true/false
  [flowrate] unavailable observed: true/false
  Reservoir sensor operational after release: true/false
  Prime outcome:                   success / incomplete (done because empty) / not observed within window / not sent
  Prime sent:                      true/false
  Normal done observed:            true/false
  Done because empty observed:     true/false
  Emergency reset asserted:        true/false
  ```

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

See SAFETY.md and PROTOCOL_AUDIT.md for the full accounting. In short: no subcommand ever loads
your saved `config.ron`, runs the Home Assistant integration, starts a profile or temperature
schedule outside its own bounded active phase, opens the Sensor subsystem, or sends `Prime` outside
`frozen-prime-test`/`frozen-prime-opensleep-init` (including its `--release-frozen-only` mode;
always sent at most once per invocation, always
manually confirmed, never scheduled or repeated automatically) or an arbitrary/undocumented
command. Every subcommand except `frozen-prime-opensleep-init` also never connects to MQTT and
never writes to `0x53` beyond a nonfatal probe -- `frozen-prime-opensleep-init` is the one
deliberate exception there (it constructs a real, never-connected MQTT client and writes to the LED
controller through the real upstream code path; see its own section above and SAFETY.md). Every
subcommand always exits after one bounded pass and is never installed as a service.
