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
  the four required `--confirm-*` flags described below. **You, the operator, are the safety
  interlock for this precondition.** There are no interactive typed confirmation phrases: a
  live-hardware run conclusively demonstrated working cooling, circulation, fan control, TEC
  operation, temperature reduction, and verified shutdown, and every phrase this mode previously
  asked for has been replaced by an explicit, auditable command-line flag instead — see "Required
  confirmations" below and `cli.rs`'s `--non-interactive` doc comment.

**Startup and shutdown now use the same narrow model as `--release-frozen-only`.** This mode no
longer runs this binary's own reimplemented four-register I2C reset sequence at startup, and no
longer runs the shared `safe_stop::run_safe_stop` (with its unconditional, hardcoded-0xFF I2C
write) at shutdown. Instead:

* Startup releases Frozen from reset via the exact same shared implementation
  (`frozen_startup::start_frozen_narrow`, built on `i2c::pulse_frozen_reset_bit`) that
  `frozen-prime-opensleep-init --release-frozen-only` uses — never
  `opensleep::reset::ResetController`, never the four-register full reset sequence, never register
  `0x07`. See that mode's own section above for the full pulse mechanics and the real-hardware
  evidence behind them.
* There is no longer a typed reservoir confirmation immediately before enabling cooling. Watch the
  reservoir yourself if you have any doubt about it; `--confirm-water-loop-filled` remains
  required, and Frozen firmware's own telemetry (`[capwater]`/`[flowrate]` sensor-unavailable
  messages, when present) is recorded either way.
* On normal completion, `DurationExpired`, reaching the requested target temperature, or a clean
  Ctrl+C/SIGTERM/SIGHUP, shutdown disables both sides over UART (three repeated attempts) and
  performs **no I2C write at all** — Frozen is left released and running, exactly as
  `--release-frozen-only` leaves it. Only if that UART-based confirmation fails *and* the stop
  reason is a genuine fault (TEC locked, a firmware fault message, temperature/heatsink out of
  range, an implausible jump, the pump not confirmed running, Frozen disabling the target on its
  own, telemetry lost/stale, a UART read/write failure, an internal panic, or an operator-reported
  leak/smell/noise) does it fall back to the narrow, bit-1-only `i2c::assert_frozen_reset_bit_only`
  — never the full reset, never registers `0x06`/`0x07`. See "Safe-stop" below for how this differs
  from every other active mode.

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
`opensleep::led`, `opensleep::mqtt::MqttManager`, and `opensleep::frozen::run`. See
`src/bin/opensleep-diagnostic/prime_opensleep_init.rs`'s module docs for the full design rationale
(real hardware evidence showed a reimplemented, partial initialization path can leave the
reservoir-level (`capwater`) sensor in a different state than a full, real OpenSleep boot does —
this mode exists to remove that gap).

**Frozen UART path is hardware-specific.** The upstream `opensleep::frozen::PORT` constant
(`/dev/ttymxc2`) is correct for the MT8365 devkit this fork's pinned upstream source targets, but
not for every Hub: a live run on this Hub completed the real subsystem reset and then failed
immediately with `Serial Io(NotFound)` when `frozen::run` was given that path. This mode calls
`frozen::run` with `/dev/ttyS1` explicitly instead (confirmed correct for this Hub, still at the
unmodified upstream 38400 baud) — the manager's protocol, wake sequence, and state machine are
untouched, only the device path differs. A preflight check refuses to proceed (before touching I2C
at all) if `/dev/ttyS1` does not exist.

**This is a different safety model, not a relaxed one:**

* This is the *only* subcommand in this binary that runs the real Frozen manager, the real MQTT
  client construction, and the real LED controller. It still never starts the Sensor subsystem at
  all (a separate physical UART with no bearing on Frozen priming — the surest way to guarantee it
  can't block priming is to never run it), never loads the operator's own saved configuration file
  (it builds its own in-memory configuration with temperature profiles disabled and MQTT never
  actually connected — see the module docs), and never runs a scheduler, alarms, or long-running
  daemon behavior: it is still a single foreground command that starts, primes once, and exits.
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
  by simply no longer polling the real Frozen manager task (the same drop-based cancellation real
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

### `--release-frozen-only`: minimal startup, no global reset

`frozen-prime-opensleep-init --release-frozen-only` is a third, even narrower safety model. It
**replaces both** the full upstream reset (`opensleep::reset::ResetController`, used by
`frozen-prime-opensleep-init` above) **and** the earlier `--preserve-boot-state` flag (removed).
Real hardware evidence drove this: after a normal boot, the reservoir-fill indicator works but
Frozen doesn't answer `Ping`; running the full reset sequence *does* release Frozen (it answers
`Ping` afterward), but it also turns the reservoir indicator off and leaves it unresponsive —
firmware then reports `[fdc1004] failed to write config` and `[capwater] sensor unavailable`. The
full reset sequence writes four I2C registers on the `0x20` expander — `0x06` (direction/config,
port 0), `0x07` (direction/config, port 1), then `0x02` (output) twice; tracing which writes
actually release Frozen showed it is the *last three* — `0x06` written to `0xFC` (configuring bits
0 and 1 as outputs), then `0x02` written to `0xFF` (bit 1 high) and then to `0xFD` (bit 1 low) — a
low→high→low **pulse** on the output latch, *after* the pin is actually configured as an output.
Register `0x07` (port 1's direction/config, unrelated to Frozen's reset bit) is never involved in
releasing Frozen at all; changing it is suspected to be what disturbs the reservoir indicator.

**Two revisions of this mode failed on real hardware before this one, for two different reasons:**

* **A one-shot clear is not sufficient.** The first revision only cleared bit 1
  (`released = original & !0x02`) without first asserting it. A live run found register `0x02`
  already reading `0xFD` (bit 1 already low) at that point, so the clear was a no-op with no edge
  on the pin, and Frozen never responded. Release is a *transition*, not a *level* — this mode
  always asserts before releasing, regardless of what bit 1 already reads as.
* **The output register alone is not sufficient either.** The second revision pulsed register
  `0x02` correctly (readbacks all verified, `0xFD → 0xFF → 0xFD`) and Frozen *still* never
  responded, because register `0x06` — which pin is configured as an output vs. an input/high-Z —
  was never touched. On the PCAL6416A, a pin configured as an input (the power-on-reset default)
  ignores its output-latch value entirely: writing register `0x02` changes what the chip *would*
  drive if it were an output, not the physical pin. This mode now configures only bit 1 of register
  `0x06` as an output before pulsing register `0x02`, and — since the reset line must stay actively
  driven, not float back to high-impedance — never restores it afterward.

**What this mode does, in order:**

1. Opens `/dev/i2c-1` and reads the PCAL6416A (`0x20`) register `0x02` — never
   `opensleep::reset::ResetController`.
2. Writes `asserted = original | 0x02` to register `0x02` and reads it back to verify — preparing
   the output latch's asserted level *before* bit 1 becomes an output (next step), so the instant
   the pin starts being driven it drives the already-intended level, avoiding an unintended release
   glitch.
3. Reads register `0x06`, computes `config = original & !0x02` — preserving bit 0 and every other
   bit exactly as read, never a hardcoded constant — verifies mathematically, before writing, that
   this can only ever change bit 1, writes it, and reads it back to verify. Whether bit 1 was
   previously input or output is logged.
4. Now that the pin is actually driven, holds the asserted level for 100ms, then computes
   `released = asserted & !0x02`, writes it to register `0x02`, and reads it back to verify.
   Register `0x06`'s original/target/readback, register `0x02`'s original/asserted/released values
   and readbacks, both changed-bit masks, and the pulse duration are all logged. **If any of the
   three readbacks doesn't match what was written, or if any bit other than bit 1 ever changed in
   either register, the run aborts before ever touching the Frozen UART.**
5. Waits up to 2 seconds, draining and logging any unsolicited boot messages Frozen sends, then
   Pings repeatedly for up to 10 more seconds. `Pong(false)` (bootloader) is followed by
   `JumpToFirmware`, then re-Pinging — tolerating any interleaved startup messages in between,
   rather than failing on the first non-`Pong` packet — until `Pong(true)`; `Pong(true)` directly
   means firmware was already running. **If Frozen never answers at all, the run aborts without
   ever sending `Prime`** — this is not treated as a fault and does not trigger an emergency reset
   (see below): Frozen is simply left released, in case it is merely slow to respond.
6. Requires typing `RESERVOIR INDICATOR IS STILL WORKING` — a **third** confirmation phrase,
   distinct from the two `frozen-prime-opensleep-init` already requires — but only once Frozen has
   reached application firmware, immediately before `Prime`. The report's `reservoir_status` field
   records the outcome explicitly as one of `confirmed`, `failed_by_operator_observation` (the
   phrase was asked and not matched), or `unverified` (the run aborted before ever asking) — it is
   never reported as a false negative merely because the confirmation was never reached.
7. Sends `Prime` exactly once, through this binary's own audited `FrozenLink`/`AuditedTransport`
   (`Mode::PrimeTest` — the same runtime mode `frozen-prime-test` uses, not the real upstream
   scheduler this file's `frozen-prime-opensleep-init` section above uses). Distinguishes
   `"[priming] done"` from `"[priming] done because empty"` exactly as every other priming mode
   does, over the firmware's up-to-600000ms observation window.
8. **On normal completion, "done because empty", or a preflight failure once Frozen has answered,
   performs no further I2C write at all** — it does not restore either register, does not re-run
   any reset, and does not touch the port in any way. Frozen is left released, configured as an
   output, and running.
9. **The only exception:** a genuine firmware-reported pump fault re-asserts *only* bit 1 of
   register `0x02` via another narrow read-modify-write (`asserted = current | 0x02`, preserving
   every other bit) — never the four-register full reset, never register `0x06` again (it is
   already configured as an output from step 3 and is left that way), and never register `0x07`.

Because this mode uses this binary's own `AuditedTransport` (unlike the rest of
`frozen-prime-opensleep-init`, which never touches it — see "Command whitelist" below), `Prime` is
still reachable at most once per run, enforced at the transport layer exactly as in
`frozen-prime-test`. Everything else about the section above still applies unless contradicted
here: the same five `--confirm-*` flags and the same two typed confirmation phrases are required
first (this mode's own reservoir phrase is a fourth check, asked later and separately, not a
replacement for them); the firmware priming window and the exact-match done/done-because-empty
distinction are unchanged.

`--dry-run --release-frozen-only` *can* run end to end against a mocked I2C expander and a mocked
Frozen device (unlike plain `frozen-prime-opensleep-init --dry-run`, which only validates
confirmations/arguments) — because, unlike the rest of this mode's sibling above, it never calls
into code that hardcodes real serial ports or I2C devices.

## Hazards specific to this hardware

* The Hub's case may contain energized areas once the cover is connected and a cooling channel or
  the priming sequence is active (pump driver, TEC driver, heatsink). **Do not touch or meter the
  open board while an active test is running.**
* Keep a way to physically disconnect Hub power available at all times during an active test —
  don't rely on software alone.
* **This binary's own audited command whitelist (`safety::AuditedTransport`) permits `Prime` in
  exactly one runtime mode: `Mode::PrimeTest`.** It cannot be constructed, whitelisted, or
  transmitted from `frozen-passive`, `frozen-cool-test`, or `emergency-stop`, under any flag
  combination — see PROTOCOL_AUDIT.md for the structural proof (a closed `FrozenAction` enum gated
  by the runtime whitelist, plus an opcode backstop). Two call sites construct `Mode::PrimeTest`:
  the `frozen-prime-test` subcommand, and `frozen-prime-opensleep-init --release-frozen-only`
  (source-level guardrail: `FrozenAction::Prime`/`FrozenAction::prime()` may only appear in
  `safety.rs`, `prime_test.rs`, or `prime_opensleep_init.rs`). At either call site, `Prime` can be
  sent at most once per invocation; a second attempt is refused at the transport layer, not merely
  avoided by this binary's own control flow. Plain `frozen-prime-opensleep-init` (without
  `--release-frozen-only`) reaches `Prime` through a structurally separate path that never touches
  `AuditedTransport` at all: it steers the real upstream Frozen scheduler (by constructing an
  in-memory configuration) into sending its own, real `FrozenCommand::Prime` -- this binary never
  constructs or transmits that command itself in that mode. See its own section above,
  `--release-frozen-only`'s own section above, and `prime_opensleep_init.rs`'s module docs.
* `Random` is never reachable in any mode: this binary's own command type cannot represent it.
* Test **only one side per invocation** in `frozen-cool-test`. `frozen-cool-test --side left` can
  never also enable `right` in the same run — see "Command whitelist" below. `Prime` itself has no
  per-side variant; it always affects both sides in one command (see PROTOCOL_AUDIT.md).
* **Stop immediately** (Ctrl+C, or run `opensleep-diagnostic emergency-stop` from a second
  session) if you observe a leak, a burning smell, abnormal noise, or anything that feels
  excessively hot.

## Command whitelist — the complete list of commands this binary's audited transport can ever send

Every outgoing Frozen command sent by `frozen-passive`, `frozen-cool-test`, `frozen-prime-test`,
`frozen-prime-opensleep-init --release-frozen-only`, and `emergency-stop` passes through
`safety::AuditedTransport::check`, which enforces a fixed per-mode whitelist (see
`src/bin/opensleep-diagnostic/safety.rs`). Plain `frozen-prime-opensleep-init` (without
`--release-frozen-only`) is the one exception -- it never uses `AuditedTransport` at all; see its
own section above for what governs it instead. The full command, opcode, and evidence table for
the audited modes is in `PROTOCOL_AUDIT.md`; in summary:

| Mode | Permitted commands |
|---|---|
| `frozen-passive` | `Ping`, `GetHardwareInfo`, `GetFirmware`, `JumpToFirmware`, `GetTemperatures`, `SetTargetTemperature(enabled=false)` for either side |
| `frozen-cool-test` | everything `frozen-passive` permits, **plus** `SetTargetTemperature(enabled=true)` for exactly the one side selected at the CLI (fixed for the whole run; the other side can only ever be sent `enabled=false`) |
| `frozen-prime-test`, `--release-frozen-only` (both run as `Mode::PrimeTest`) | everything `frozen-passive` permits, **plus** `Prime`, at most once per run |
| `emergency-stop` | `SetTargetTemperature(enabled=false)` for LEFT and RIGHT, and the `0x20` reset-assert write only |

**Never reachable through `AuditedTransport`, in any of the five audited modes:** `Random(_)`, any
raw/undocumented opcode, an absolute (non-derived) temperature target, or a simultaneously-enabled
left+right target.
**`Prime` (`0x52`)** is reachable through `AuditedTransport` in exactly one runtime mode
(`Mode::PrimeTest`, constructed by `frozen-prime-test` and by `--release-frozen-only`, at most once
per run either way) — never in `frozen-passive`, `frozen-cool-test`, or `emergency-stop`. This is
enforced structurally in two independent layers (a closed `FrozenAction` enum, plus the runtime
whitelist gate with its own at-most-once check for `Prime`), not by
convention — see `safety::tests` and
PROTOCOL_AUDIT.md.

## Active-test limits (hard-coded; no CLI flag can override them)

* Exactly one side per invocation; cooling only (no heating) in this first build. The other side is
  explicitly disabled before the test starts and stays that way for the whole run.
* Default cooling delta: 1.0C below the measured baseline, used only when neither `--delta-c` nor
  `--target-c` is supplied — this default is not a maximum. **There is no fixed host-side maximum
  delta any more**: a live-hardware run conclusively demonstrated working cooling, circulation, fan
  control, TEC operation, temperature reduction, and verified shutdown well above the former 2.0C
  cap, and `safety::FrozenAction::enable_cooling` no longer refuses to construct a command purely
  for exceeding it — Frozen firmware itself remains responsible for PID regulation, TEC current
  protection, thermal protection, and target maintenance. A resulting delta above 2.0C requires the
  explicit `--confirm-large-temperature-delta` acknowledgement (an audit trail, not a second hidden
  cap). `enable_cooling` still refuses a non-positive delta and a resulting target outside a
  conservative 0–45C absolute backstop, independent of delta size. `--target-c` sets an absolute
  target directly instead of a delta below baseline; it is mutually exclusive with `--delta-c` and
  validated against the measured baseline once that's known.
* Default active duration: **120 seconds** — long enough to establish meaningful water-temperature
  movement through the filled cover loop. **Absolute maximum: 900 seconds (15 minutes)** —
  `cool_test::run` refuses to start at all if `--duration-seconds` exceeds this. Requesting more
  than 300 seconds requires the explicit `--confirm-extended-test` acknowledgement and prints a
  reminder that the operator must remain present for the whole run and continuously monitor for
  leaks, a burning smell, abnormal pump noise, loss of circulation, or unexpected heating. A long
  duration is not a long minimum wait: in the legacy active loop, the test always stops early once
  the requested target temperature is reached *and stays reached* for a short confirmation window
  (never on a single noisy sample, and the TEC is never kept enabled merely to consume the rest of
  the requested duration once that's confirmed); in `--firmware-authoritative` mode, target
  attainment is logged but no longer stops the test early at all (Frozen keeps maintaining it for
  the rest of the requested duration). Either mode still stops early if a safety condition
  triggers, communication with Frozen is lost, or the operator interrupts (see below).
* The selected TEC's safety-interlock state is parsed into explicit states
  (`cool_test::TecSafetyState`), not matched by raw substring: `"safe, unlocking"` and `"unlocked"`
  are positive, non-fault transitions; only `"unsafe, locking"` and the exact word `"locked"` are
  treated as a safety shutdown. An earlier revision matched TEC lock state with
  `contains("tec") && contains("lock")`, which also matches `"unlocking"`/`"unlocked"` (both
  contain the substring `"lock"`) and aborted a healthy, actively-cooling run on exactly that
  message — a real live-hardware regression this fix corrected. The same substring trap existed
  independently in the generic firmware-fault keyword scan and was fixed the same way.
* The baseline is collected over **at least 10 seconds** of stable samples (at least 5), and
  collection continues for up to **60 seconds** if that many valid samples haven't arrived yet —
  never a single reading. Samples come from unsolicited `TemperatureUpdate` pushes and decoded
  solicited `GetTemperature` replies (both the original 27-byte reply and, since revision 13, the
  14-byte reply some Frozen firmware sends — see PROTOCOL_AUDIT.md); a reading duplicated across
  two packet types in the same poll is only counted once.
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
Ctrl+C, SIGTERM/SIGHUP, and the duration expiring. Every abort assigns and logs a specific reason
before shutdown begins (`beginning controlled shutdown: stop_reason=<code>`), and that reason
appears in the text, JSON, and CSV reports (`stop_reason`/`stop_reason_code`) — there is no path
into shutdown that skips this.

* **Communication watchdog**: no successfully decoded packet of *any* kind (temperature update,
  firmware message, target state, ...) for more than 5 seconds — a genuine silence timeout,
  distinct from a UART write/read failure or the link closing outright, which abort immediately
  rather than after a grace period.
* **Temperature watchdog**: a valid temperature sample (either the unsolicited push or a decoded
  solicited reply — see below) had already arrived at least once during the active phase, but none
  arrived for more than 20 seconds. **Temperature startup grace**: no temperature sample arrived at
  all within 15 seconds of the target being enabled. These two are deliberately *not* the same
  clock as the communication watchdog above: a live-hardware incident found the active phase
  aborting almost exactly 2 seconds after enabling, on ordinary pump/TEC startup chatter, because
  an earlier revision used one 2-second clock refreshed only by the unsolicited temperature push —
  shorter than this firmware's own ~10-second unsolicited-push cadence, so it fired on every run
  regardless of any actual fault. The current 20s/15s limits were sized from that same real-hardware
  evidence, with margin.
* The selected-side water temperature or the heatsink temperature leaves the compile-time safe
  range, or changes implausibly fast in a single ~1-second tick. This check now runs on *every*
  decoded temperature reading — the unsolicited push, a solicited 27-byte reply, or this firmware's
  14-byte reply — not the unsolicited push alone.
* The selected-side pump still reports off/0V (via a decoded firmware message) more than 3 seconds
  after the enable command was accepted. This only fires if the firmware has actually reported the
  pump as off — it never fires merely because no pump message was seen at all.
* A firmware message reports the selected TEC's safety interlock as `"unsafe, locking"` or exactly
  `"locked"` — parsed by explicit word, never by substring (see below for why that distinction
  matters). The positive states `"safe, unlocking"` and `"unlocked"` are recorded and the active
  phase continues; they never abort anything.
* Frozen reports the selected side disabled on its own, after this tool enabled it.
* A firmware message contains a fault keyword (overtemperature, overcurrent, shutdown, fault,
  failed, locked) more than 2 seconds into the active phase — giving a brief startup grace period
  so ordinary boot-time chatter isn't mistaken for a fault. As with the TEC check, "locked"/"fault"
  here are matched by exact word, not substring — "locked" does not match `"unlocked"`, "fault"
  does not match `"default"`. `"flash locked"` and any `"[temps]"` health-report message (e.g.
  `"[temps] 0 reads failed out of 1200"`, real firmware's own zero-failure status counter) are
  excluded outright, regardless of which words they contain — legacy-mode-only: see
  `--firmware-authoritative` below for why that mode removed keyword-based fault detection
  entirely instead of adding more excluded cases.
* **You type `ABORT` and press Enter** (or a report of a leak, smell, or noise — see below).

### TEC safety-interlock false positive (fixed)

A live left-side cooling test successfully enabled the target and reached active hardware control
(`FW: tec[left] current: 11.402626 A`), then aborted immediately on `FW: tec[left] safe,
unlocking` — logged as "firmware reported the selected TEC locked". False positive: "safe,
unlocking" is the interlock reporting it is safe to run, not a fault. Two bugs, found and fixed
across two passes: first, `contains("tec") && contains("lock")` also matches `"unlocking"`/
`"unlocked"` (both contain the substring `"lock"`) — replaced with word-tokenized classification
that can never conflate the two. Second, even after that parser fix, the *caller* still collapsed
the parser's recognized positive result into a generic terminal outcome — replaced with an
exhaustive match over every state, so a positive state can never again be silently treated as
terminal by a caller that only checked "did the parser recognize something."

Firmware messages reporting `[capwater]` or `[flowrate]` sensor unavailable are recorded as
warnings, not treated as an automatic abort condition on their own — they have been observed with
the cover connected and the reservoir filled, and flow itself is not exercised until a pump
actually runs during an active test.

**Not a fault, but also ends the active phase early:** once the selected side's live temperature
reaches the computed target (baseline minus the requested delta), the test stops on its own rather
than continuing to cool for the rest of the configured duration — reported as `target_reached` in
the JSON output, distinct from every fault condition above.

### Typing ABORT during `frozen-cool-test`'s active phase

Once the active phase starts, this tool prints a reminder and reads your terminal input in the
background for the rest of the run. If you observe a leak, a burning smell, or abnormal mechanical
noise, **type a word describing it (e.g. `LEAK`) or the literal word `ABORT`, then press Enter** —
this stops the test immediately, exactly like Ctrl+C. Unrecognized input is ignored and logged; it
does not abort the run. (`frozen-prime-test` does not have this typed-input path — see below for
why watching the reservoir and pressing Ctrl+C is that mode's primary operator-stop mechanism.)

## `--firmware-authoritative`: an optional, narrower active-phase mode

A live cooling test enabled the selected side successfully — the pump was commanded, the solenoid
opened, and the operator physically heard water flowing — but the run stopped seconds later with
`pump_startup_failure`. Root cause: three `pump[left] off @ 0.000000V` reports were sitting in the
host's own read buffer from *before* the enable command was even acknowledged, and the active loop
had no way to distinguish that stale, pre-enable evidence from a genuine post-enable failure. This
is a host-side telemetry race, not evidence the pump actually failed — the same class of problem
(the diagnostic second-guessing Frozen firmware based on incomplete or misordered telemetry) as the
TEC false positive above, but this time in the pump-confirmation logic instead of the TEC-state
parser.

`--firmware-authoritative` is an opt-in flag for `frozen-cool-test` that removes this entire class
of host-side inference. What changes is what happens *after* the target is confirmed enabled:

* Frozen firmware becomes the sole authority on pump sequencing, TEC ramping, PID control, solenoid
  control, fan control, current safety, thermal regulation, and target maintenance. This tool
  becomes an observer plus a bounded stop timer.
* **Telemetry received before the enabled `TargetUpdate` is actually confirmed — not merely "some
  reply arrived" — is tagged pre-enable and never actioned as active-phase state.** This is the
  direct fix for the incident above: an internal generation counter and timestamp only begin once
  the real confirmation is seen; a stale `pump[left] off` report from before that point is recorded
  in the raw report but can never trigger a shutdown.
* The host-side heuristics that used to be able to end a legacy run — pump-startup-not-confirmed,
  the communication watchdog (5s), the temperature watchdog (20s) and startup grace (15s), and the
  generic firmware fault-keyword scan — are all disabled in this mode. Reaching the computed target
  temperature is logged but no longer stops the test: Frozen continues maintaining it for the rest
  of the requested duration.
* In their place, this mode recognizes a small, closed set of legitimate automatic stop conditions:
  the requested duration expiring, operator abort (typed or Ctrl+C/SIGTERM/SIGHUP), an explicit TEC
  safety-lock message (`"unsafe, locking"` or exactly `"locked"` — same word-exact parser as the
  legacy loop), an explicit recognized firmware safety-fault message, the enabled target being
  explicitly lost, a fatal UART error, an internal error, and one remaining communication check: no
  valid packet of *any* kind for 30 seconds (a deliberately much longer, single threshold than the
  legacy loop's 5s/20s watchdogs — long enough that it cannot plausibly be confused with this
  firmware's own telemetry cadence, but still a backstop against a truly dead link).
* Positive evidence is still tracked and reported even though its *absence* is never a fault: pump
  command/status messages (both the `"pump[<side>] ... @ <V>V <A>A"` format and the
  `"[pump-<side>] <command>=><value>"` format — both captured from the same incident), TEC current
  and safety-interlock messages, `[temps]` read-health telemetry, both fans' telemetry, and observed
  target attainment. Missing TEC-current, fan, or pump telemetry produces a logged warning, never a
  stop.
* An independent shutdown guard, armed only once the target is confirmed enabled (never for
  `--dry-run`), runs as a genuinely separate OS process — not a thread — so it survives the main
  process crashing, hanging, or being killed outright, which an in-process construct cannot. It
  uses the same disable-first, narrow-emergency-reset-only-as-last-resort sequence as every other
  shutdown path in this tool, and only fires if the main process's own verified shutdown never
  disarms it before its own timer (the requested duration plus a 30-second grace period) elapses.

### The next false positive: `"0 reads failed out of 1200"` (fixed)

A later left-side run *conclusively demonstrated working cooling, circulation, fan control, TEC
operation, temperature reduction, and verified shutdown* in `--firmware-authoritative` mode — the
pre-enable race above was confirmed fixed. But the same class of bug resurfaced once more: Frozen
sent `FW: [temps] 0 reads failed out of 1200` — its own healthy status counter, zero failures — and
the generic firmware-fault keyword scan this mode still ran classified it as
`explicit_firmware_safety_fault`, because the scan matched the word `"failed"` anywhere in the
message, regardless of context.

Fixed by removing generic keyword-based fault detection from `--firmware-authoritative` mode
**entirely** — not by adding another excluded word to the list (the same trap that keeps
recurring), but structurally: an automatic firmware-fault shutdown in this mode now requires a
specifically parsed, recognized negative state, exactly like `TecSafetyState` already was. A
firmware `Message` this tool cannot specifically parse and recognize as negative is always
observational and nonterminal, no matter what words it contains. `"[temps] <N> reads failed out of
<M>"` is now its own parser (`cool_test::parse_temps_health_report`), reported as
`temperature_reads_failed`/`temperature_reads_total`/`temperature_read_failure_ratio` — purely
descriptive, never itself a reason to stop at any count. The legacy (non-`--firmware-authoritative`)
active loop keeps its keyword scan (unchanged, still evidence-gated and word-exact where a prior
incident required it — see above), with `"[temps]"` messages now also excluded there as a direct,
narrower fix for the same evidence.

Also fixed in the same pass: fan telemetry (`"FW: [top-fan] <duty> @ <rpm> rpm"` /
`"FW: [bottom-fan] <duty> @ <rpm> rpm"`) is Hub-wide thermal management, not scoped to either
cooling side — real captured messages have no left/right identifier at all. Both loops' "was fan
telemetry observed" check no longer looks for the selected side's own tag (which a fan message
could never contain), and `--firmware-authoritative` reports `top_fan_*`/`bottom_fan_*` activity,
latest duty/RPM, and max RPM directly.

`--firmware-authoritative` does not change the required confirmations, the hard limits, or the
guaranteed shutdown sequence below — it changes what the active phase watches for and what it does
about what it sees.

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

There are no interactive typed confirmation phrases: a live-hardware run conclusively demonstrated
working cooling, circulation, fan control, TEC operation, temperature reduction, and verified
shutdown, and every phrase this mode previously asked for (`I CONFIRM THE WATER LOOP IS CONNECTED
AND FILLED`, a second phrase naming the selected side, and a third reservoir-indicator phrase) has
been removed. The command never pauses to wait for typed input; `--non-interactive` documents this
explicitly and additionally guarantees no post-run questionnaire either (see below). Two more
command-line flags are required only in the specific situations they apply to:

* `--confirm-extended-test` — required when `--duration-seconds` exceeds 300. Replaces the former
  `RUN EXTENDED COOLING TEST FOR UP TO 15 MINUTES` phrase.
* `--confirm-large-temperature-delta` — required when the requested (or, via `--target-c`,
  computed) cooling delta exceeds 2.0C. An auditable acknowledgement only, not a second maximum —
  see "Active-test limits" above.

A fully specified command with every flag it needs proceeds straight through to enabling cooling
with no further prompts.

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
that logic — in `frozen-prime-test` and `emergency-stop` alike. It always: sends
`SetTargetTemperature(enabled=false)` for LEFT and RIGHT three times with short delays, flushes the
UART, and asserts `0x20` subsystem reset (`reg 0x02 <- 0xFF`), leaving the subsystem in that
asserted-reset state. A run is only reported PASS if this completes successfully. If the UART
disable fails but the I2C reset succeeds, the run is reported **degraded**, not PASS. If the I2C
reset *also* fails, the program prints an explicit instruction to disconnect Hub power immediately.

**`frozen-prime-test` always runs this same safe-stop, including the `0x20` reset, at the end of
every invocation — even when `"priming done"` was observed.** No Prime-cancellation command exists
in the reused protocol (see PROTOCOL_AUDIT.md), so subsystem reset is the only forced-stop
mechanism available; it is not a substitute for a graceful "stop priming" command, because none
exists to substitute for.

**`frozen-cool-test` is the one exception: it never calls `safe_stop::run_safe_stop`.** Its own
shutdown (`cool_test::run_cool_test_shutdown`) sends the same three repeated
`SetTargetTemperature(enabled=false)` attempts and flushes the UART, but asserts **no** I2C reset
at all on a normal stop — only the narrow, bit-1-only `i2c::assert_frozen_reset_bit_only` (never
the shared routine's hardcoded-0xFF `i2c::assert_reset`), and only when UART-based confirmation
failed for a genuine fault (see "Startup and shutdown" in this mode's own section above). A run is
reported PASS only if either UART confirmation or the emergency reset succeeded; if UART
confirmation failed and no fault warranted the emergency reset (a duration/target-reached/Ctrl+C
stop with a non-responsive link), shutdown is reported unverified and the program prints an
explicit warning to reboot the Hub or disconnect power if cooling does not visibly stop —
`frozen-cool-test` never overwrites bits it doesn't need to touch just to force a PASS.

## Keep a second session open

Before starting `frozen-cool-test` or `frozen-prime-test`, open a second SSH session to the Hub
with this ready to run:

```sh
opensleep-diagnostic emergency-stop
```

`emergency-stop` requires no config, MQTT, Sensor, or LED access, and works even if Frozen itself
is unresponsive (it best-effort-disables both sides, then unconditionally asserts the I2C reset,
which is the real backstop). It exits non-zero if the reset could not be confirmed.

## What no subcommand ever does, including `frozen-prime-opensleep-init`

* **Never open the Sensor subsystem UART or reference it at all, in any mode.** Sensor is a
  separate physical UART with no bearing on Frozen priming or on `capwater`/`flowrate` reporting
  (both come from Frozen's own firmware messages) -- even `frozen-prime-opensleep-init`, which runs
  the real Frozen manager, the real MQTT client construction, and the real LED controller, does not
  start it. This is enforced by `guardrail_tests` in `main.rs` scanning the diagnostic's own
  sources at test time: no file, `frozen-prime-opensleep-init` included, may reference it.
* Never write to the `0x53` LED controller other than through the real, already-nonfatal upstream
  code path (`frozen-prime-opensleep-init`) or a read-only, nonfatal probe (every other mode).

## What `frozen-passive`, `frozen-cool-test`, `frozen-prime-test`, and `emergency-stop` never do

* Never load the operator's own saved configuration file, never connect to MQTT, never run the
  Home Assistant integration.
* Never call the real Frozen manager's command-scheduling loop or any profile/scheduled-priming
  logic -- `frozen-prime-test` only ever sends one manually-confirmed `Prime`, nothing resembling
  the daily-scheduled automatic priming stock OpenSleep performs.
* Never install or touch a systemd unit; every run is a single foreground pass, manually initiated
  every time -- priming is never automatic.

These are enforced both by the fact that these four modes' own source never references those code
paths (`guardrail_tests` in `main.rs` scans the diagnostic's own sources at test time to prove it)
and by the command whitelist above.

## What `frozen-prime-opensleep-init` does differently, and what still never happens even there

This mode is the one deliberate exception to the second list above except its last bullet: it
*does* run the real Frozen manager (that is the entire point -- see its own section above) and
*does* construct a real MQTT client (never connected), and *does* write to the LED controller
through the real, already-nonfatal upstream code path. Even so:

* It still never starts the Sensor subsystem, exactly like every other mode -- see "What no
  subcommand ever does" above.
* It still never reads the operator's own saved configuration file from disk -- it builds its own
  in-memory configuration (see `prime_opensleep_init.rs` module docs).
* It still never runs the Home Assistant integration or any scheduler/alarm/long-running behavior
  beyond the single Prime this run exists to send.
* It still never installs or touches a systemd unit; it is still a single foreground pass, manually
  initiated every time, exactly like every other subcommand.
* `guardrail_tests` in `main.rs` prove all of the above by scanning source, including that
  `frozen-prime-opensleep-init` is the *only* file referencing the real Frozen manager, the MQTT
  client, or the LED controller driver -- and that even it never references the real
  configuration-file loader, `rumqttc`, or an obsolete MT8365-devkit UART path directly.
