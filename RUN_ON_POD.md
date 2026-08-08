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
  that releases Frozen from reset with a single-bit I2C pulse instead of the full upstream reset
  sequence — see that flag's own section below and in SAFETY.md.
* `opensleep-diagnostic frozen-cool-test` — intentionally activates one cooling channel; requires
  a connected, *already-filled* hydraulic loop and multiple explicit confirmations. Starts Frozen
  the same narrow way `--release-frozen-only` does, and performs no I2C write at all on a normal
  stop. **Read SAFETY.md before running this.**
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
curl -L -O https://github.com/ortega-io/opensleep-diagnostic/releases/download/diagnostic-v21/opensleep-diagnostic-aarch64-static
curl -L -O https://github.com/ortega-io/opensleep-diagnostic/releases/download/diagnostic-v21/opensleep-diagnostic-aarch64-static.sha256
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
full reset does release Frozen, but it also reconfigures I2C expander register `0x07` (unrelated to
Frozen's reset bit) and leaves the reservoir-fill indicator off and unresponsive afterward. This
mode instead touches only bit 1 of two registers, and never register `0x07` at all:

1. Configures only bit 1 of register `0x06` (direction/config) as an output — `config = original &
   !0x02`, preserving bit 0 and every other bit — since on the PCAL6416A a bit configured as an
   input (the power-on-reset default) ignores its output-latch value entirely.
2. **Pulses** only bit 1 of register `0x02` (output) — writes `asserted = original | 0x02`,
   verifies the readback, waits 100ms, then writes `released = asserted & !0x02` and verifies that
   readback too.

Both steps matter, and were found the hard way on real hardware: a one-shot clear of register
`0x02` (no preceding assert) failed because the register was already reading `0xFD` (bit 1 already
low), so clearing it again was a no-op with no edge. A register-`0x02`-only pulse (assert then
release, correctly) *also* failed, because register `0x06` was never touched — bit 1 was never
actually configured as an output, so the chip never physically drove the pin at all. **Read the
`--release-frozen-only` section of SAFETY.md before using this — it is a third, narrower safety
model, not a relaxed one.**

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

You'll be prompted for the same two typed phrases as plain `frozen-prime-opensleep-init`. After the
I2C pulse, this mode waits up to 2 seconds for boot messages, then Pings repeatedly for up to 10
more seconds; if Frozen never answers, the run aborts without ever sending `Prime`. Once Frozen has
reached application firmware, and immediately before `Prime` is sent, you'll be asked for a
**third** phrase:

```
Type RESERVOIR INDICATOR IS STILL WORKING to continue:
```

Only type this if the reservoir-fill indicator is genuinely still responding after Frozen was
released. This mode's own report includes a `reservoir_status` field recording the outcome
explicitly: `confirmed` (you typed the exact phrase), `failed_by_operator_observation` (you were
asked and did not), or `unverified` (the run aborted before ever asking — never reported as a false
negative just because the confirmation was never reached).

* On normal completion, `"done because empty"`, or a preflight failure once Frozen has answered,
  this mode performs **no further I2C write at all** on exit — it does not restore either register
  and does not run any reset. Frozen is left released, configured as an output, and running. If
  priming does not visibly stop, reboot the Hub or disconnect Hub power.
* The only exception is a genuine firmware-reported pump fault, which re-asserts bit 1 of register
  `0x02` only (never the full four-register reset, never register `0x06` again -- it stays
  configured as an output from step 1 above -- and never register `0x07`).
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
  Register 0x02 original:          0b11111111
  Asserted (output latch, pre-direction): target=0b11111111 readback=0b11111111 matches=true
  Register 0x06 original:          0b11111111
  Register 0x06 configured-as-output: target=0b11111101 readback=0b11111101 matches=true (bit 1 was previously input)
  Released: target=0b11111101 readback=0b11111101 matches=true
  Only bit 1 changed (all three writes): true
  Pulse duration (driven):         100 ms
  Frozen UART opened:              true/false
  Frozen reached firmware:         true/false
  [capwater] unavailable observed: true/false
  [flowrate] unavailable observed: true/false
  Reservoir status:                confirmed / failed_by_operator_observation / unverified
  Prime outcome:                   success / incomplete (done because empty) / not observed within window / not sent
  Prime sent:                      true/false
  Normal done observed:            true/false
  Done because empty observed:     true/false
  Emergency reset asserted:        true/false
  ```

## 7. Once the loop is confirmed filled: run a cooling test on one side

Only proceed here once you've confirmed water movement and a stable reservoir level from step 6
(or already knew the loop was filled and skipped step 6).

`--delta-c 1.0` and `--duration-seconds 120` are both already the defaults; they're spelled out
below for clarity. Only the selected side is ever enabled -- the other side is explicitly disabled
before the test starts and stays that way for the whole run.

**This mode now starts Frozen the same way `--release-frozen-only` does** (see that flag's own
section above and SAFETY.md) -- a narrow, single-bit I2C pulse, never the full upstream reset --
and, on a normal stop, its own shutdown performs **no I2C write at all**, leaving Frozen released
and running (never the old always-assert-0x20-reset behavior). Read SAFETY.md's `frozen-cool-test`
section before running this if you haven't already.

There are no interactive typed confirmation phrases: the four `--confirm-*` flags below are the
complete acknowledgement mechanism, and the command proceeds straight through to enabling cooling
with no further prompts. `--non-interactive` documents this explicitly.

```sh
/persistent/tools/opensleep-diagnostic frozen-cool-test \
    --side left \
    --delta-c 1.0 \
    --duration-seconds 120 \
    --firmware-authoritative \
    --non-interactive \
    --confirm-cover-hydraulics-connected \
    --confirm-water-loop-filled \
    --confirm-no-visible-leaks \
    --confirm-active-test \
    --json-output /persistent/frozen-cool-left.json \
    --csv-output /persistent/frozen-cool-left.csv \
    --verbose
```

`--firmware-authoritative` is recommended: once the target is confirmed enabled, Frozen firmware
owns pump sequencing, TEC ramping, PID control, solenoid control, fan control, current safety,
thermal regulation, and target maintenance, and this tool becomes an observer plus a bounded stop
timer -- it will not disable cooling merely because its own inferred pump/TEC/temperature state is
incomplete, delayed, reordered, or temporarily stale. Omit it to use the legacy active loop's
narrower host-side heuristics instead (see SAFETY.md for exactly how the two differ).

One more flag is required only in the specific situation it applies to:

* `--confirm-large-temperature-delta` -- required when the requested (or, via `--target-c`,
  computed) cooling delta exceeds 2.0C. There is no fixed maximum delta any more -- this flag is an
  auditable acknowledgement, not a second cap. `--target-c <TARGET_C>` sets an absolute target
  directly instead of a delta below baseline, and is mutually exclusive with `--delta-c`.

There is no diagnostic-imposed maximum duration any more, and no separate confirmation flag for a
long run (the former `--confirm-extended-test` flag was removed along with the 900-second ceiling
it existed to gate). `--duration-seconds 3600` still works exactly as before; for a longer,
human-readable duration use `--duration <DURATION>` instead (`30m`, `1h`, `4h`, `8h30m` -- mutually
exclusive with `--duration-seconds`). A duration above 300 seconds prints a reminder, not a
required flag, that you must remain present and continuously monitor for leaks, a burning smell,
abnormal pump noise, loss of circulation, or unexpected heating for the whole run. Every active
test still requires *some* finite duration -- there is no "run forever" mode.

During the active phase, watch/listen (without touching or metering the open board) for:

* Pump sound or vibration
* Fan movement or airflow
* Unexpected noise
* Leaks
* A burning smell

If you observe any of the last three, **type `ABORT` (or a word like `LEAK`) and press Enter**, or
press **Ctrl+C** immediately, or run `emergency-stop` from your second session -- all three stop
the test (typed ABORT still works even with `--non-interactive`, as long as stdin is actually a
terminal; SIGINT/SIGTERM handling is always active regardless). Pressing Ctrl+C does **not** exit
immediately: the process disables both sides over UART (three repeated attempts) before it exits,
exactly like every other stop reason, and performs no I2C write at all for a clean interrupt.

With `--firmware-authoritative`, the tool otherwise only stops automatically for: the requested
duration expiring, an explicit TEC safety-lock message, an explicit recognized firmware
safety-fault message, the enabled target being explicitly lost, a fatal UART error, an internal
error, or ~30 seconds of total communication silence. Reaching the requested target is logged but
does *not* stop the test -- Frozen keeps maintaining it for the rest of the requested duration.
Without that flag, the legacy loop also stops on: reaching the requested target temperature (not a
fault), the selected pump still reporting off/0V more than 3 seconds after being enabled, a
firmware fault-keyword message after a brief startup grace period, and its own separate
communication/temperature watchdogs -- see SAFETY.md for the complete comparison. Only a genuine
fault among these, combined with UART-based shutdown confirmation failing, triggers the narrow
emergency I2C reset; every other stop reason performs no I2C write.

By default, raw hexadecimal RX/TX byte dumps are never printed (even with `--verbose`) -- add
`--raw-serial-log` if you specifically need them; it works independently of `--verbose`.

There is no post-run questionnaire: the JSON report always includes `"operator observation: not
collected"` for anything this tool cannot verify electronically, rather than pausing for input.
Attach a free-text note with `--operator-note "<text>"` if you want one recorded -- never required.

`--side left`/`--side right` tests exactly one side per invocation; repeat with the other side as a
separate run if desired. `--side both` (see below) tests both simultaneously in one run instead.

### Reading the cooling result

The JSON/text summary reports each component separately — never collapses them into one
pass/fail:

```
Frozen command accepted:        PASS/FAIL/UNKNOWN
Pump operation:                 PASS/FAIL/UNVERIFIED
Fan operation:                  PASS/FAIL/UNVERIFIED
TEC cooling operation:          PASS/FAIL/UNVERIFIED
Telemetry remained valid:       PASS/FAIL
Controlled shutdown:            PASS/FAIL
Overall selected-side result:   PASS/FAIL/INCONCLUSIVE
```

("Controlled shutdown" reads "Emergency shutdown" instead only on the rare run where the narrow
emergency I2C reset genuinely fired, e.g. because UART-based shutdown confirmation itself failed.)

See PROTOCOL_AUDIT.md for exactly what evidence can ever produce a PASS for each line — in
particular, pump/fan/TEC are never marked PASS merely because the command was accepted.

### Simultaneous dual-side operation: `--side both`

`--side both` enables left and right for the same bounded test and disables them together at
shutdown -- it **requires `--firmware-authoritative`** (the legacy loop's host-side heuristics are
single-side only by design; see SAFETY.md). `--target-c` sends the exact same absolute target to
both sides; `--delta-c` applies the same delta independently to each side's own measured baseline
(the two resulting targets may differ slightly if the baselines do).

```sh
/persistent/tools/opensleep-diagnostic frozen-cool-test \
    --side both \
    --delta-c 1.0 \
    --duration 4h \
    --firmware-authoritative \
    --non-interactive \
    --confirm-cover-hydraulics-connected \
    --confirm-water-loop-filled \
    --confirm-no-visible-leaks \
    --confirm-active-test \
    --json-output /persistent/frozen-cool-both.json \
    --csv-output /persistent/frozen-cool-both.csv \
    --verbose
```

The active phase does not begin observing until *both* sides' enabled `TargetUpdate` is explicitly
confirmed over UART. If only one side confirms, both are immediately disabled and the run never
continues with one side active. A fault on either side (an explicit TEC safety-lock message, or the
enabled target being explicitly lost) stops both sides together, never just the one that faulted.

### Long, unattended, or session-independent runs

Every run above prints a compact progress line about once a minute (elapsed/remaining time, each
side's current temperature and target, pump/fan state) instead of repeating every unchanged reading
at INFO level -- useful for tailing a multi-hour log. An `--firmware-authoritative` run is also
protected by an independent shutdown guard process the whole time (see SAFETY.md): it holds its own
copy of the requested deadline and disables the relevant side(s) even if the main process dies,
hangs, or the terminal running it disconnects.

**Stdin closing is not itself treated as an abort** -- only the literal typed `ABORT` command is,
and only while stdin is actually a live terminal. Ctrl+C/SIGTERM still trigger the same controlled
shutdown as any other stop reason regardless of whether stdin is a terminal. This binary does not
auto-daemonize, so a run you want to survive your SSH session ending should be started under
`systemd-run` or `nohup` rather than left attached to an interactive shell:

```sh
# systemd-run: supervised, journal-logged, survives the SSH session ending
systemd-run --unit=frozen-cool-both --collect \
    /persistent/tools/opensleep-diagnostic frozen-cool-test \
    --side both --delta-c 1.0 --duration 4h --firmware-authoritative --non-interactive \
    --confirm-cover-hydraulics-connected --confirm-water-loop-filled \
    --confirm-no-visible-leaks --confirm-active-test \
    --json-output /persistent/frozen-cool-both.json --verbose
# journalctl -u frozen-cool-both -f       # tail the run
# systemctl stop frozen-cool-both         # SIGTERM -> the same controlled shutdown as Ctrl+C

# nohup: simpler, no systemd unit, also survives SIGHUP from the closing terminal
nohup /persistent/tools/opensleep-diagnostic frozen-cool-test \
    --side both --delta-c 1.0 --duration 4h --firmware-authoritative --non-interactive \
    --confirm-cover-hydraulics-connected --confirm-water-loop-filled \
    --confirm-no-visible-leaks --confirm-active-test \
    --json-output /persistent/frozen-cool-both.json --verbose \
    > /persistent/frozen-cool-both.log 2>&1 &
disown
# tail -f /persistent/frozen-cool-both.log
# kill <pid>                              # SIGTERM -> the same controlled shutdown as Ctrl+C
```

Either way, `emergency-stop` from a second session remains available as a last resort regardless of
how the run was started (see "Keep a second session open" in SAFETY.md).

## 8. Investigating the Sensor subsystem, independently of Frozen

`sensor-probe` is unrelated to the hydraulic workflow above: it never touches Frozen's UART or the
water loop, and can be run at any point, in any order, relative to the Frozen steps above (it does
not require the cover to be connected or the reservoir filled). It defaults to `/dev/ttyS2` (the
candidate Sensor UART on this MT8365 Hub) — override with `--sensor-port` if needed.

**Start with `--passive` (the default) — zero UART writes, zero I2C writes:**

```sh
opensleep-diagnostic sensor-probe --listen-seconds 20 --json-output /tmp/sensor-passive.json
```

This opens `/dev/ttyS2` at 115200 baud, listens for 20 seconds, then repeats at 38400 baud, and
reports byte/frame counts and any decoded packet types for each — without ever writing a byte to
the UART or the I2C bus. Review the output before doing anything more active.

**`--ping`: confirm two-way communication, without changing Sensor's mode:**

```sh
opensleep-diagnostic sensor-probe --ping --verbose
```

Sends up to 3 `Ping` packets at firmware baud (115200); only if that stays silent, up to 3 more at
bootloader baud (38400). Never sends `JumpToFirmware`.

**`--discover`: the full upstream discovery sequence, plus optional read-only info queries and an
observation window:**

```sh
opensleep-diagnostic sensor-probe --discover --query-info --observe-seconds 60 \
    --json-output /tmp/sensor-discover.json --csv-output /tmp/sensor-discover.csv
```

Pings firmware baud first; only if silent, pings bootloader baud; only if *that* responds, sends
exactly one `JumpToFirmware` and re-pings at firmware baud. `--query-info` (only sent after a
confirmed firmware-mode `Pong`) additionally requests `GetHardwareInfo`/`GetFirmwareHash`. Once
communication is established, listens for unsolicited traffic (capacitance/piezo/temperature/
messages) for `--observe-seconds` (default 60) and summarizes what was seen, including per-side
capacitance/piezo min/max/latest values when those packets appear. Never starts the normal Sensor
command scheduler and never sends a vibration, alarm, piezo-configuration, or presence-calibration
command — see SAFETY.md.

**Read-only PCAL6416A expander audit** (combinable with any mode above):

```sh
opensleep-diagnostic sensor-probe --passive --listen-seconds 1 --audit-expander --verbose
```

Reads (never writes) the expander's input/output/config/polarity registers and prints each in hex
and binary. Safe to run at any time, including with Frozen actively running a test in another
session — it reads the same I2C bus but never contends for a write.

**If Sensor stays silent:** `overall_result: "uart_silent"` is expected, informative output, not a
crash or a claim of hardware failure — see SAFETY.md's `sensor-probe` section for why plain
discovery deliberately stops there instead of guessing at a reset/enable line for the Sensor MCU.

### EXPERIMENTAL: testing the suspected Sensor enable line (port-0 bit 0)

If plain discovery above stays silent, `--enable-suspected-sensor-line` tests one specific,
narrowly-scoped hypothesis: that bit 0 of the PCAL6416A's port-0 registers is a Sensor enable/
reset-release/power-enable line (real hardware evidence: it's the one bit that differs between
upstream OpenSleep's own reset sequence and this fork's proven narrow Frozen-only initialization,
and upstream never drives it low). It configures that bit as an output, driven HIGH, and nothing
else — never a pulse, never LOW, never bit 1 (Frozen's own reset bit), never register `0x07`. Read
SAFETY.md's "revision 20" section before running this.

**Narrowest form — enable the line, send zero Sensor UART commands, just listen:**

```sh
opensleep-diagnostic sensor-probe --passive --enable-suspected-sensor-line \
    --listen-seconds 30 --json-output /tmp/sensor-line-passive.json --verbose
```

Watch for `overall_result: "spontaneous_sensor_traffic_after_line_enable"` and a small
`first_rx_after_enable_ms`/`first_decoded_packet_after_enable_ms` in the report — the strongest
possible evidence of a causal link, since this binary never sent the Sensor MCU a single byte.

**Full discovery after enabling the line** (mirrors upstream's own bootloader-first ordering,
`38400` before `115200`, unlike plain `--discover` above):

```sh
opensleep-diagnostic sensor-probe --discover --enable-suspected-sensor-line --query-info \
    --json-output /tmp/sensor-line-discover.json
```

**State is preserved on exit, not automatically reverted** — if bit 0 really is a Sensor enable
line, reverting it immediately would make the experiment impossible to interpret. To explicitly
restore bit 0 to whatever it read before this same invocation changed it (add to either command
above, in the same invocation — it cannot be used on its own in a later run):

```sh
opensleep-diagnostic sensor-probe --discover --enable-suspected-sensor-line \
    --restore-suspected-sensor-line --json-output /tmp/sensor-line-discover.json
```

Check `reg_0x02_original`/`reg_0x02_final` and `reg_0x06_original`/`reg_0x06_final` in the JSON
output to confirm exactly what changed and (if `--restore-suspected-sensor-line` was used) that it
changed back. `overall_result: "expander_verification_failed"` means the expander itself didn't
behave as expected (a readback mismatch, or a bit other than bit 0 changed) — Sensor UART probing
is skipped entirely in that case, and no further action was taken.

### EXPERIMENTAL: combined narrow subsystem init (port-0 bits 0 and 1)

If bit-0-only above left Sensor silent, `--combined-narrow-subsystem-init` additionally configures
bit 1 (Frozen's own, already-proven reset line) as an output and pulses it exactly as already
proven for Frozen, while bit 0 stays asserted HIGH — reproducing only the port-0 portion of
upstream's own startup sequence, never touching register `0x07` (this Hub's own `0x77`) or any
other register. Opt-in; cannot be combined with `--enable-suspected-sensor-line`,
`--restore-suspected-sensor-line`, or `--audit-expander`. Read SAFETY.md's "revision 21" section
before running this.

```sh
opensleep-diagnostic sensor-probe --combined-narrow-subsystem-init --query-info \
    --json-output /tmp/sensor-combined-init.json --verbose
```

This performs the three-write expander sequence (verified before proceeding), then verifies Frozen
is reachable with a single Ping (no temperature target, no Prime, no pump or cooling — verification
only), then probes Sensor using upstream's own bootloader-first discovery ordering. Check
`frozen_reached_firmware`, `sensor_bootloader_confirmed`/`sensor_firmware_confirmed`, and
`combined_reg07_preserved` in the JSON output. State is **not** automatically reverted on exit —
there is no `--restore` option for this mode in this version. `overall_result:
"sensor_still_silent_after_combined_init"` or `"frozen_alive_sensor_silent"` are expected,
informative outcomes, not proof of a Sensor hardware failure.

## Dry-run mode (safe on any development machine, no hardware needed)

Every subcommand accepts `--dry-run`, which performs no I2C or UART writes at all and instead runs
the same logic against a mocked Frozen device and a mocked I2C bus:

```sh
opensleep-diagnostic frozen-passive --dry-run --json-output /tmp/dryrun-passive.json
opensleep-diagnostic frozen-prime-test --dry-run \
    --confirm-cover-hydraulics-connected --confirm-reservoir-filled \
    --confirm-cover-loop-needs-priming --confirm-no-visible-leaks --confirm-active-test \
    --json-output /tmp/dryrun-prime.json
opensleep-diagnostic frozen-cool-test --side left --dry-run --non-interactive \
    --firmware-authoritative \
    --confirm-cover-hydraulics-connected --confirm-water-loop-filled \
    --confirm-no-visible-leaks --confirm-active-test \
    --json-output /tmp/dryrun-cool.json
opensleep-diagnostic emergency-stop --dry-run
opensleep-diagnostic sensor-probe --discover --query-info --dry-run --json-output /tmp/dryrun-sensor.json
opensleep-diagnostic sensor-probe --discover --enable-suspected-sensor-line --restore-suspected-sensor-line \
    --dry-run --json-output /tmp/dryrun-sensor-line.json
opensleep-diagnostic sensor-probe --combined-narrow-subsystem-init --query-info --dry-run \
    --json-output /tmp/dryrun-sensor-combined.json
```

`frozen-prime-test --dry-run` still requires its interactive typed confirmations unless stdin is
not a TTY (e.g. when piping input in a script or CI). `frozen-cool-test --dry-run` has no
interactive typed confirmations at all any more -- the four `--confirm-*` flags above are
sufficient regardless of `--non-interactive`. Dry-run never silently switches to live mode — if it
can't run against the mock, it refuses, the same as live mode would.

## What this tool will never do on the Pod

See SAFETY.md and PROTOCOL_AUDIT.md for the full accounting. In short: no subcommand ever loads
your saved `config.ron`, runs the Home Assistant integration, starts a profile or temperature
schedule outside its own bounded active phase, opens the Sensor subsystem's UART (except
`sensor-probe` itself, whose own guarantees are described in step 8 above and in SAFETY.md), opens
Frozen's UART from `sensor-probe` (except `--combined-narrow-subsystem-init`'s own Ping-only
verification step, which never sets a target, primes, or starts a pump/cooling), or sends `Prime`
outside
`frozen-prime-test`/`frozen-prime-opensleep-init` (including its `--release-frozen-only` mode;
always sent at most once per invocation, always
manually confirmed, never scheduled or repeated automatically) or an arbitrary/undocumented
command. Every subcommand except `frozen-prime-opensleep-init` also never connects to MQTT and
never writes to `0x53` beyond a nonfatal probe -- `frozen-prime-opensleep-init` is the one
deliberate exception there (it constructs a real, never-connected MQTT client and writes to the LED
controller through the real upstream code path; see its own section above and SAFETY.md). Every
subcommand always exits after one bounded pass and is never installed as a service.
