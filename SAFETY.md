# SAFETY.md — opensleep-diagnostic

`opensleep-diagnostic` is a staged, **Frozen-only** hardware diagnostic for an Eight Sleep Pod 3
Hub. Four of its five subcommands are not a fork of normal `opensleep` and do not run its control
loops, timers, MQTT client, profile scheduler, or Sensor/LED management. The fifth,
`frozen-prime-opensleep-init`, is the one deliberate exception — see its own section below for
exactly what that means and why. None of the five installs a systemd service or runs unattended —
every invocation is a single foreground command that starts, does its work, and exits.

**Read this whole document before running `frozen-cool-test`, `frozen-prime-test`, or
`frozen-prime-opensleep-init` on real hardware.**

## The safety tiers

### `frozen-passive` — safe with the cover disconnected and no water

`frozen-passive` may be run with the mattress cover disconnected and the hydraulic reservoir
empty. It never intentionally activates a pump, fan, valve, TEC, or the priming sequence. The only
actuator-shaped command it can ever send is `SetTargetTemperature` with `enabled = false` (a
"safety-off"), which turns nothing on.

### `frozen-cool-test` — an active test; **must not** run with the cover disconnected

`frozen-cool-test` **must not** run with the cover disconnected or the hydraulic loop unfilled.
Running the earlier passive test successfully, with the cover disconnected, is **not** permission
to run this mode — the two are independent, and `frozen-cool-test` re-checks its own preflight
conditions and refuses to start unless it receives explicit confirmation, every time.

* The hydraulic loop must be connected and filled before this mode is started.
* Visually check for leaks before starting.
* This binary structurally cannot verify "is the cover physically connected" — it can only trust
  the four `--confirm-*` flags and the typed confirmation phrases described below. **You, the
  operator, are the safety interlock for this precondition.**

### `frozen-prime-test` — an active test; **fills an empty or partially-filled loop**

`frozen-prime-test` intentionally sends `Prime` (opcode `0x52`) exactly once, to run the hydraulic
purge/fill sequence. Unlike `frozen-cool-test`, this mode is meant to be run *before* the loop is
fully filled, specifically to fill it — but it still requires the cover connected, the reservoir
topped up with water ready to be drawn in, and the same explicit-confirmation discipline.

* The cover's hydraulic lines must be connected before this mode is started.
* The reservoir must contain water — `Prime` draws it into the loop; it does not create water.
* Visually check for leaks before starting.
* **You must watch the reservoir continuously for the entire run and be ready to press Ctrl+C.**
  The firmware does not expose a reliable reservoir-level signal on this hardware (`capwater` has
  been observed unavailable) — this tool cannot detect an empty reservoir on your behalf. See
  "Automatic abort conditions during `frozen-prime-test`" below.
* There is no Prime-cancellation command anywhere in the reused protocol (see PROTOCOL_AUDIT.md).
  Subsystem reset (I2C `0x20`) is the only forced-stop mechanism, exactly as for every other mode.

### `frozen-prime-opensleep-init` — the same operation, through real OpenSleep initialization

`frozen-prime-opensleep-init` sends `Prime` exactly once, just like `frozen-prime-test` — but
instead of this binary's own reimplemented I2C reset sequence and Frozen UART transport, it calls
the real, unmodified upstream `opensleep::reset::ResetController::reset_subsystems`,
`opensleep::led`, `opensleep::mqtt::MqttManager`, `opensleep::sensor::run`, and
`opensleep::frozen::run`. See `src/bin/opensleep-diagnostic/prime_opensleep_init.rs`'s module docs
for the full design rationale (real hardware evidence showed a reimplemented, partial
initialization path can leave the reservoir-level (`capwater`) sensor in a different state than a
full, real OpenSleep boot does — this mode exists to remove that gap).

**This is a different safety model, not a relaxed one:**

* This is the *only* subcommand in this binary that runs the real Frozen manager, the real MQTT
  client construction, the real Sensor subsystem, and the real LED controller. It still never loads
  the operator's own saved configuration file (it builds its own in-memory configuration with
  temperature profiles disabled and MQTT never actually connected — see the module docs) and never
  runs a scheduler, alarms, or long-running daemon behavior: it is still a single foreground
  command that starts, primes once, and exits.
* Frozen must already be running application firmware (`Ping` must get `Pong(true)`) before this
  mode sends anything else. If it is not, the tool refuses to start and tells you to reboot the Hub
  — it never attempts a bootloader → firmware jump.
* **If firmware reports `[capwater] sensor unavailable` as a result of this run's own
  initialization, `Prime` is never sent.** The tool prints the initialization sequence and
  subsystem state that produced this so you can diagnose it, and refuses to proceed.
* The observation window is fixed at the firmware-reported priming duration (600000 ms) and is not
  configurable.
* On exit — normal completion, `"done because empty"`, the window elapsing, or a stop signal — this
  mode does **not** assert the I2C subsystem reset. Frozen's own firmware returns to idle on its
  own after priming ends; forcing a reset immediately afterward would be needlessly disruptive to a
  subsystem this mode is specifically trying to leave in its normal, running state. Shutdown happens
  by simply no longer polling the real Frozen/Sensor tasks (the same drop-based cancellation real
  `opensleep`'s own top-level `tokio::select!` already uses), not by resetting anything.
* The one exception: a genuine firmware-reported pump fault observed during the run **does** assert
  an emergency I2C reset, using this diagnostic's own already-audited `assert_reset` primitive (not
  a reimplementation of upstream's reset sequence).
* Temperature targets are never enabled during this run (the constructed configuration has an empty
  temperature profile, which the real scheduler always treats as disabled, regardless of time of
  day) — there is nothing to actively disable at shutdown.
* Everything else about `frozen-prime-test` above still applies: the same five `--confirm-*` flags,
  the same two typed confirmation phrases, `Prime` sent at most once, and the same exact-match
  distinction between `"[priming] done"` (success) and `"[priming] done because empty"`
  (incomplete, not success).

Use this mode when you specifically want the fill/priming operation verified against real OpenSleep
behavior rather than this binary's own reimplemented transport — e.g. after `frozen-prime-test`
reports `[capwater]`/`[flowrate]` unavailable and you want to rule out that reimplementation as the
cause.

## Hazards specific to this hardware

* The Hub's case may contain energized areas once the cover is connected and a cooling channel or
  the priming sequence is active (pump driver, TEC driver, heatsink). **Do not touch or meter the
  open board while an active test is running.**
* Keep a way to physically disconnect Hub power available at all times during an active test —
  don't rely on software alone.
* **This binary's own audited command whitelist (`safety::AuditedTransport`) permits `Prime` in
  exactly one mode: `frozen-prime-test`.** It cannot be constructed, whitelisted, or transmitted
  from `frozen-passive`, `frozen-cool-test`, or `emergency-stop`, under any flag combination — see
  PROTOCOL_AUDIT.md for the structural proof (a closed `FrozenAction` enum gated by the runtime
  whitelist, plus an opcode backstop). Within `frozen-prime-test` itself, `Prime` can be sent at
  most once per invocation; a second attempt is refused at the transport layer, not merely avoided
  by this binary's own control flow. `frozen-prime-opensleep-init` reaches `Prime` through a
  structurally separate path that never touches `AuditedTransport` at all: it steers the real
  upstream Frozen scheduler (by constructing an in-memory configuration) into sending its own,
  real `FrozenCommand::Prime` -- this binary never constructs or transmits that command itself in
  that mode. See its own section above and `prime_opensleep_init.rs`'s module docs.
* `Random` is never reachable in any mode: this binary's own command type cannot represent it.
* Test **only one side per invocation** in `frozen-cool-test`. `frozen-cool-test --side left` can
  never also enable `right` in the same run — see "Command whitelist" below. `Prime` itself has no
  per-side variant; it always affects both sides in one command (see PROTOCOL_AUDIT.md).
* **Stop immediately** (Ctrl+C, or run `opensleep-diagnostic emergency-stop` from a second
  session) if you observe a leak, a burning smell, abnormal noise, or anything that feels
  excessively hot.

## Command whitelist — the complete list of commands this binary's audited transport can ever send

Every outgoing Frozen command sent by `frozen-passive`, `frozen-cool-test`, `frozen-prime-test`,
and `emergency-stop` passes through `safety::AuditedTransport::check`, which enforces a fixed
per-mode whitelist (see `src/bin/opensleep-diagnostic/safety.rs`). `frozen-prime-opensleep-init` is
the one exception -- it never uses `AuditedTransport` at all; see its own section above for what
governs it instead. The full command, opcode, and evidence table for the audited modes is in
`PROTOCOL_AUDIT.md`; in summary:

| Mode | Permitted commands |
|---|---|
| `frozen-passive` | `Ping`, `GetHardwareInfo`, `GetFirmware`, `JumpToFirmware`, `GetTemperatures`, `SetTargetTemperature(enabled=false)` for either side |
| `frozen-cool-test` | everything `frozen-passive` permits, **plus** `SetTargetTemperature(enabled=true)` for exactly the one side selected at the CLI (fixed for the whole run; the other side can only ever be sent `enabled=false`) |
| `frozen-prime-test` | everything `frozen-passive` permits, **plus** `Prime`, at most once per run |
| `emergency-stop` | `SetTargetTemperature(enabled=false)` for LEFT and RIGHT, and the `0x20` reset-assert write only |

**Never reachable through `AuditedTransport`, in any of the four audited modes:** `Random(_)`, any
raw/undocumented opcode, an absolute (non-derived) temperature target, or a simultaneously-enabled
left+right target.
**`Prime` (`0x52`)** is reachable through `AuditedTransport` in exactly one mode
(`frozen-prime-test`, at most once per run) — never in `frozen-passive`, `frozen-cool-test`, or
`emergency-stop`. This is enforced structurally in two independent layers (a closed `FrozenAction`
enum, plus the runtime whitelist gate with its own at-most-once check for `Prime`), not by
convention — see `safety::tests` and
PROTOCOL_AUDIT.md.

## Active-test limits (hard-coded; no CLI flag can override them)

* Exactly one side per invocation; cooling only (no heating) in this first build. The other side is
  explicitly disabled before the test starts and stays that way for the whole run.
* Default cooling delta: 1.0C below the measured baseline. **Maximum permitted delta: 2.0C** —
  `safety::FrozenAction::enable_cooling` refuses to construct a command for a larger delta.
* Default active duration: **10 seconds**, chosen conservatively for a first test. **Absolute
  maximum: 30 seconds** — `cool_test::run` refuses to start at all if `--duration-seconds` exceeds
  this.
* The baseline water temperature must fall within **15.00C–35.00C**
  (`cool_test::MIN_WATER_CENTIDEG`/`MAX_WATER_CENTIDEG`) before the test proceeds. This range is a
  conservative, compile-time choice (not derived from a documented firmware spec — see
  PROTOCOL_AUDIT.md for why no tighter, evidence-backed range could be established) intended to
  reject a disconnected/faulted sensor (implausible highs/lows, `0`/`0xFFFF` sentinels) while still
  accepting any plausible indoor ambient-to-body-adjacent water temperature.
* No arbitrary/absolute commands.

## `frozen-prime-test` limits (hard-coded; no CLI flag can override them)

* `Prime` has no per-side variant; one command affects both sides. There is no `--side` flag.
* Default observation duration: **30 seconds**. Minimum: **5 seconds** — a shorter window cannot
  meaningfully observe anything. **Absolute maximum: 60 seconds** — `prime_test::run` refuses to
  start at all if `--duration-seconds` is outside `[5, 60]`.
* If firmware reports priming complete (`"FW: [priming] done"` or `"...done because empty"`)
  before the configured duration elapses, the test stops early and runs safe-stop immediately —
  it never waits out the rest of the window once completion is observed.
* `frozen-prime-opensleep-init` replaces this whole limits list with its own fixed, non-overridable
  600000 ms (firmware-reported) observation window — see its own section above.
* The operator may run another separate priming cycle after inspecting and refilling the
  reservoir. **This tool never automatically repeats or restarts `Prime`.**

## Automatic abort conditions during `frozen-cool-test`'s active phase

The active phase aborts itself (and always runs safe-stop) on any of the following, in addition to
Ctrl+C, SIGTERM/SIGHUP, and the duration expiring:

* No fresh, valid unsolicited temperature update for more than 2 seconds.
* The selected-side water temperature or the heatsink temperature leaves the compile-time safe
  range, or changes implausibly fast in a single ~1-second tick.
* A UART write or read failure, or the link to Frozen closing.
* The selected-side pump still reports off/0V (via a decoded firmware message) more than 3 seconds
  after the enable command was accepted. This only fires if the firmware has actually reported the
  pump as off — it never fires merely because no pump message was seen at all.
* A firmware message reports the selected TEC as locked.
* Frozen reports the selected side disabled on its own, after this tool enabled it.
* A firmware message contains a fault keyword (overtemperature, overcurrent, shutdown, fault,
  failed, locked) more than 2 seconds into the active phase — giving a brief startup grace period
  so ordinary boot-time chatter isn't mistaken for a fault.
* **You type `ABORT` and press Enter** (or a report of a leak, smell, or noise — see below).

Firmware messages reporting `[capwater]` or `[flowrate]` sensor unavailable are recorded as
warnings, not treated as an automatic abort condition on their own — they have been observed with
the cover connected and the reservoir filled, and flow itself is not exercised until a pump
actually runs during an active test.

### Typing ABORT during `frozen-cool-test`'s active phase

Once the active phase starts, this tool prints a reminder and reads your terminal input in the
background for the rest of the run. If you observe a leak, a burning smell, or abnormal mechanical
noise, **type a word describing it (e.g. `LEAK`) or the literal word `ABORT`, then press Enter** —
this stops the test immediately, exactly like Ctrl+C. Unrecognized input is ignored and logged; it
does not abort the run. (`frozen-prime-test` does not have this typed-input path — see below for
why watching the reservoir and pressing Ctrl+C is that mode's primary operator-stop mechanism.)

## Automatic abort conditions during `frozen-prime-test`'s active phase

The active phase aborts itself (and always runs safe-stop) on any of the following, in addition to
Ctrl+C, SIGTERM/SIGHUP, and the duration expiring:

* No fresh, valid unsolicited temperature update for more than 2 seconds.
* Either side's water temperature, or the heatsink temperature, leaves the compile-time safe
  range (`Prime` affects both sides at once, so both are checked every tick).
* A UART write or read failure, or the link to Frozen closing.
* A firmware message explicitly names a pump fault.
* I2C access to the `0x20` reset/enable expander fails once priming has started (periodically
  re-checked during the run).
* A periodic Ping shows Frozen has fallen back to bootloader mode.
* An unsolicited `TargetUpdate` reports either side enabled — this mode must never have an enabled
  target at any point.
* A firmware message contains a fault keyword (overtemperature, overcurrent, shutdown, fault,
  failed, locked) — except inside a cataloged `[priming]`-stage message, where "failed" is known,
  evidenced, routine purge-retry accounting (see PROTOCOL_AUDIT.md), not a fatal condition by
  itself; the firmware's own "done"/"done because empty" messages are the authoritative completion
  signals for that channel.

Firmware messages reporting `[capwater]` or `[flowrate]` sensor unavailable are recorded as
warnings, not treated as an automatic abort condition. This tool does **not** infer that low pump
current means the reservoir is empty — no source evidence establishes a reliable threshold for
that, so it does not guess. **Watching the reservoir and pressing Ctrl+C is the primary safety
interlock for an empty reservoir; this tool cannot substitute for it.**

## Required confirmations before `frozen-cool-test` can run

All of the following are required; missing any one refuses the run before any I2C/UART access:

```
--side left|right
--confirm-cover-hydraulics-connected
--confirm-water-loop-filled
--confirm-no-visible-leaks
--confirm-active-test
```

Additionally, unless standard input is not a TTY, you must type the exact phrase:

```
I CONFIRM THE WATER LOOP IS CONNECTED AND FILLED
```

...and, after preflight validates the baseline and prints the proposed target, a second exact
phrase naming the selected side, e.g.:

```
START LEFT COOLING TEST
```

Neither confirmation accepts `yes`/`no`/a shortened form.

## Required confirmations before `frozen-prime-test` can run

All of the following are required; missing any one refuses the run before any I2C/UART access:

```
--confirm-cover-hydraulics-connected
--confirm-reservoir-filled
--confirm-cover-loop-needs-priming
--confirm-no-visible-leaks
--confirm-active-test
```

Additionally, unless standard input is not a TTY, you must type the exact phrase:

```
I CONFIRM THE RESERVOIR IS FILLED AND THE COVER IS CONNECTED
```

Before sending `Prime`, this tool prints:

```
WARNING: Priming may rapidly lower the reservoir water level.
Watch the reservoir continuously.
Stop immediately if the reservoir approaches empty.
Keep access to disconnect Hub power.
Do not touch the open electronics while powered.
```

...and then requires a second exact phrase:

```
START SUPERVISED PRIMING
```

Neither confirmation accepts `yes`/`no`/a shortened form.

## Safe-stop

One shared-pattern routine (`safe_stop::run_safe_stop`) runs before every active test, on normal
completion, on Ctrl+C/SIGTERM/SIGHUP, on timeout, on any communication or telemetry error, and
(via a `catch_unwind` boundary around the per-tick evaluation logic) after an internal panic in
that logic — in `frozen-cool-test`, `frozen-prime-test`, and `emergency-stop` alike. It always:
sends `SetTargetTemperature(enabled=false)` for LEFT and RIGHT three times with short delays,
flushes the UART, and asserts `0x20` subsystem reset (`reg 0x02 <- 0xFF`), leaving the subsystem in
that asserted-reset state. A run is only reported PASS if this completes successfully. If the UART
disable fails but the I2C reset succeeds, the run is reported **degraded**, not PASS. If the I2C
reset *also* fails, the program prints an explicit instruction to disconnect Hub power immediately.

**`frozen-prime-test` always runs this same safe-stop, including the `0x20` reset, at the end of
every invocation — even when `"priming done"` was observed.** No Prime-cancellation command exists
in the reused protocol (see PROTOCOL_AUDIT.md), so subsystem reset is the only forced-stop
mechanism available; it is not a substitute for a graceful "stop priming" command, because none
exists to substitute for.

## Keep a second session open

Before starting `frozen-cool-test` or `frozen-prime-test`, open a second SSH session to the Hub
with this ready to run:

```sh
opensleep-diagnostic emergency-stop
```

`emergency-stop` requires no config, MQTT, Sensor, or LED access, and works even if Frozen itself
is unresponsive (it best-effort-disables both sides, then unconditionally asserts the I2C reset,
which is the real backstop). It exits non-zero if the reset could not be confirmed.

## What `frozen-passive`, `frozen-cool-test`, `frozen-prime-test`, and `emergency-stop` never do

* Never load the operator's own saved configuration file, never connect to MQTT, never run the
  Home Assistant integration.
* Never call the real Frozen manager's command-scheduling loop or any profile/scheduled-priming
  logic -- `frozen-prime-test` only ever sends one manually-confirmed `Prime`, nothing resembling
  the daily-scheduled automatic priming stock OpenSleep performs.
* Never open the Sensor subsystem UART or reference it at all.
* Never write to the `0x53` LED controller — only ever a read-only, nonfatal probe.
* Never install or touch a systemd unit; every run is a single foreground pass, manually initiated
  every time -- priming is never automatic.

These are enforced both by the fact that these four modes' own source never references those code
paths (`guardrail_tests` in `main.rs` scans the diagnostic's own sources at test time to prove it)
and by the command whitelist above.

## What `frozen-prime-opensleep-init` does differently, and what still never happens even there

This mode is the one deliberate exception to every bullet above except the last two: it *does* run
the real Frozen manager (that is the entire point -- see its own section above), *does* construct a
real MQTT client (never connected) and a real Sensor subsystem task (best-effort, never gating
Prime), and *does* write to the LED controller through the real, already-nonfatal upstream code
path. Even so:

* It still never reads the operator's own saved configuration file from disk -- it builds its own
  in-memory configuration (see `prime_opensleep_init.rs` module docs).
* It still never runs the Home Assistant integration or any scheduler/alarm/long-running behavior
  beyond the single Prime this run exists to send.
* It still never installs or touches a systemd unit; it is still a single foreground pass, manually
  initiated every time, exactly like every other subcommand.
* `guardrail_tests` in `main.rs` prove all of the above by scanning source, including that
  `frozen-prime-opensleep-init` is the *only* file referencing the real Frozen manager, MQTT
  client, Sensor subsystem, or LED controller driver -- and that even it never references the real
  configuration-file loader or `rumqttc` directly.
