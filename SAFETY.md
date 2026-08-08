# SAFETY.md — opensleep-diagnostic

`opensleep-diagnostic` is a staged hardware diagnostic for an Eight Sleep Pod 3 Hub, historically
**Frozen-only** and now joined by one Sensor-only subcommand. Four of its five Frozen subcommands
are not a fork of normal `opensleep` and do not run its control loops, timers, MQTT client, profile
scheduler, or Sensor/LED management. The fifth, `frozen-prime-opensleep-init`, is the one
deliberate exception — see its own section below for exactly what that means and why. The sixth
subcommand, `sensor-probe`, is unrelated to Frozen entirely: it investigates the Sensor MCU over
its own UART — see its own section below. None of the six installs a systemd service or runs
unattended — every invocation is a single foreground command that starts, does its work, and
exits.

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
`frozen-prime-opensleep-init --release-frozen-only`, `emergency-stop`, `frozen-hold-start`,
`frozen-hold-stop`, and `frozen-hold-status` passes through `safety::AuditedTransport::check`,
which enforces a fixed per-mode whitelist (see `src/bin/opensleep-diagnostic/safety.rs`). Plain
`frozen-prime-opensleep-init` (without `--release-frozen-only`) is the one exception -- it never
uses `AuditedTransport` at all; see its own section above for what governs it instead. The full
command, opcode, and evidence table for the audited modes is in `PROTOCOL_AUDIT.md`; in summary:

| Mode | Permitted commands |
|---|---|
| `frozen-passive` | `Ping`, `GetHardwareInfo`, `GetFirmware`, `JumpToFirmware`, `GetTemperatures`, `SetTargetTemperature(enabled=false)` for either side |
| `frozen-cool-test` | everything `frozen-passive` permits, **plus** `SetTargetTemperature(enabled=true)` for exactly the one side selected at the CLI (fixed for the whole run; the other side can only ever be sent `enabled=false`) |
| `frozen-prime-test`, `--release-frozen-only` (both run as `Mode::PrimeTest`) | everything `frozen-passive` permits, **plus** `Prime`, at most once per run |
| `emergency-stop` | `SetTargetTemperature(enabled=false)` for LEFT and RIGHT, and the `0x20` reset-assert write only |
| `frozen-hold-start` (revision 22) | `Ping`, `GetHardwareInfo`, `GetFirmware`, `JumpToFirmware`, `GetTemperatures` (the no-reset responsiveness probe and narrow-startup fallback), `SetTargetTemperature(enabled=false)` (rollback only), and the one absolute, non-derived `SetTargetTemperature(enabled=true)` target for either side -- see the revision 22 section below |
| `frozen-hold-stop` (revision 22) | `Ping` (logging only, never gates a reset), `SetTargetTemperature(enabled=false)` for LEFT and RIGHT |
| `frozen-hold-status` (revision 22) | `Ping`, `GetHardwareInfo`, `GetFirmware`, `JumpToFirmware`, `GetTemperatures` only -- never any `SetTargetTemperature` |

**Never reachable through `AuditedTransport`, in any of `frozen-passive`, `frozen-cool-test`,
`frozen-prime-test`/`--release-frozen-only`, `emergency-stop`, or `frozen-hold-stop`/
`frozen-hold-status`:** `Random(_)`, any raw/undocumented opcode, an absolute (non-derived)
temperature target, or a simultaneously-enabled left+right target. `frozen-hold-start` is the one
deliberate, narrow exception to "no absolute target": it exists specifically to send one, exactly
once per side, per its own spec -- see the revision 22 section below for the closed `HoldTarget`
constructor and its own validation.
**`Prime` (`0x52`)** is reachable through `AuditedTransport` in exactly one runtime mode
(`Mode::PrimeTest`, constructed by `frozen-prime-test` and by `--release-frozen-only`, at most once
per run either way) — never in `frozen-passive`, `frozen-cool-test`, `emergency-stop`, or any of the
three `frozen-hold-*` modes. This is enforced structurally in two independent layers (a closed
`FrozenAction` enum, plus the runtime whitelist gate with its own at-most-once check for `Prime`),
not by convention — see `safety::tests` and PROTOCOL_AUDIT.md.

`sensor-probe` is entirely separate from `AuditedTransport`/`FrozenAction` above -- it speaks a
different protocol over a different UART, gated by its own closed `SensorProbeAction` enum and
`sensor_safety::ProbeMode` whitelist (`--passive` permits nothing, `--ping` permits only `Ping`,
`--discover` permits `Ping`/`JumpToFirmware` always and `GetHardwareInfo`/`GetFirmwareHash` only
once firmware-mode communication is confirmed). See `sensor-probe`'s own section above and
`sensor_safety.rs`.

## Active-test limits (hard-coded; no CLI flag can override them)

* `--side left`/`--side right` enables exactly one side; cooling only (no heating). The other side
  is explicitly disabled before the test starts and stays that way for the whole run. `--side both`
  (revision 18+) enables both sides for the same bounded test and disables them together at
  shutdown — it **requires `--firmware-authoritative`**, since the legacy active loop's per-tick
  host-side heuristics (pump-startup confirmation, the communication/temperature watchdogs) are
  single-side by design and do not generalize to two independently progressing sides. `--side both`
  is never represented as a distinct value on the wire: Frozen still receives one ordinary
  `SetTargetTemperature` for Left and one for Right, sent back-to-back with no unrelated polling
  interleaved between the two writes, and the active phase does not begin observing until *both*
  sides' enabled `TargetUpdate` is explicitly confirmed. If only one side confirms, this is treated
  as its own terminal condition (`partial_dual_side_enable`): both sides are immediately disabled
  and the run never continues with only one side active. For `--target-c` with `--side both`, the
  exact same absolute target is sent to both sides (each still validated against its own measured
  baseline); for `--delta-c` with `--side both`, the same delta is applied independently to each
  side's own baseline, so the two resulting targets may differ slightly.
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
  movement through the filled cover loop, used only when neither `--duration` nor
  `--duration-seconds` is supplied. **There is no diagnostic-imposed maximum duration** (revision
  18+ removed the former hard 900-second/15-minute ceiling): a 900-second live-hardware run
  conclusively demonstrated working cooling, pump/fan/TEC operation, and verified shutdown at that
  duration, making the old ceiling an artificial host-side limitation rather than a demonstrated
  Frozen limitation. Every active test still requires an explicit, finite duration — there is no
  "run forever" mode — accepted either as `--duration-seconds <N>` (an integer count of seconds,
  kept for backward compatibility) or the human-readable `--duration <DURATION>` (e.g. `30m`, `1h`,
  `4h`, `8h30m`; the two flags are mutually exclusive). `--duration` is parsed with the
  integer-backed `humantime` crate — never through floating-point hours — and is only rejected for
  being zero, failing to parse, being unrepresentable as a `std::time::Duration`, or causing the
  monotonic deadline computation to overflow (checked arithmetic throughout, via
  `Instant::checked_add`). Requesting more than 300 seconds prints a reminder (not a required
  acknowledgement flag — the former `--confirm-extended-test` flag was removed along with the
  ceiling it existed to gate, since the four required `--confirm-*` flags are already sufficient
  acknowledgement) that the operator must remain present for the whole run and continuously monitor
  for leaks, a burning smell, abnormal pump noise, loss of circulation, or unexpected heating. Every
  active `--firmware-authoritative` run — one-side or `--side both` — is additionally protected by
  an independent shutdown guard process (see below) that holds its own copy of the finite deadline
  and disables the relevant side(s) even if the main process dies. A long duration is not a long
  minimum wait: in the legacy active loop, the test always stops early once
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

### Revision 18: hours-long runs and simultaneous dual-side operation

A 900-second right-side `--firmware-authoritative` run completed successfully (target reached and
maintained, pump/fan/TEC evidence PASS, 0 of 1200 firmware-reported temperature reads failed,
verified shutdown), demonstrating the former 900-second ceiling was an artificial host-side test
limitation, not a demonstrated Frozen limitation. Revision 18 removed that ceiling (see "Active-test
limits" above) and added `--side both` for simultaneous left+right operation, always gated on
`--firmware-authoritative` for the reason given there. Three changes specific to this revision:

* **Per-side terminal conditions.** A `--side both` run recognizes the same closed set of stop
  conditions as a one-side run, doubled: `explicit_left_tec_unsafe_locking`/
  `explicit_left_tec_locked` and their right-side counterparts, and `enabled_left_target_explicitly_lost`/
  `enabled_right_target_explicitly_lost`. A fault on *either* side stops *both* — cooling is never
  left running on one side while the other has been disabled for a fault. `partial_dual_side_enable`
  (only one of the two requested sides confirmed enabled) is its own terminal condition: the active
  phase never begins in that state, and both sides are immediately disabled, verified, and the
  independent guard disarmed only after that verification.
* **The independent shutdown guard now detects a hung — not just a dead — parent.** Previously it
  only noticed the main process exiting (its stdin pipe closing). It now also requires a periodic
  heartbeat byte from *within* the main process's own per-tick active loop (every 10s, timing out
  after 45s of silence) — a genuinely stuck loop (not merely a slow one) stops heartbeating too, and
  the guard treats heartbeat loss identically to parent death: an immediate, controlled disable of
  every side that run may have activated. The guard is also now explicitly immune to a terminal
  disconnecting: it runs in its own process group (so a SIGHUP delivered to the parent's controlling
  terminal is never delivered to it) and additionally consumes SIGINT/SIGTERM/SIGHUP itself in a
  loop that never exits on any of them — only its own disarm byte or firing ends it.
* **Terminal/SSH disconnection is distinct from stdin closing.** SIGINT/SIGTERM initiate the same
  controlled both-side shutdown as any other stop condition. Stdin closing (e.g. a redirected or
  piped invocation) is not itself treated as an abort — only the literal typed `ABORT` command is,
  and only while stdin is actually a live TTY. For a run expected to outlive the invoking terminal
  session, use `systemd-run` or `nohup` (see RUN_ON_POD.md) rather than relying on the process
  surviving an SSH disconnect on its own; this binary does not auto-daemonize.

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
explicitly and additionally guarantees no post-run questionnaire either (see below). One more
command-line flag is required only in the specific situation it applies to:

* `--confirm-large-temperature-delta` — required when the requested (or, via `--target-c`,
  computed) cooling delta exceeds 2.0C. An auditable acknowledgement only, not a second maximum —
  see "Active-test limits" above.

(Revision 18 removed the former `--confirm-extended-test` flag along with the duration ceiling it
existed to gate — a duration above 300 seconds now only prints a reminder, not a required flag; see
"Active-test limits" above.)

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

## `sensor-probe` — investigates the Sensor subsystem, independently of Frozen

`sensor-probe` is a sixth subcommand with a narrower goal than the five Frozen-only modes above:
establish reliable UART communication with the Sensor MCU (the presence/piezo/temperature board,
not Frozen's hydraulic controller) and decode whatever is already available. **This first version
deliberately does not attempt presence calibration, piezo configuration, vibration actuation,
alarms, or any expander reset pulsing.** See `sensor_probe.rs` module docs for the full design.

* **Zero I2C writes in every mode by default.** `--passive`, `--ping`, and `--discover` never call
  `I2cPort::write_reg` at all; `--audit-expander` (combinable with any mode) only ever calls
  `read_reg`. The one opt-in exception is `--enable-suspected-sensor-line` -- see its own
  subsection below; every other flag combination is still enforced structurally (no other
  `write_reg` call exists anywhere in
  `sensor_probe.rs`/`sensor_link.rs`/`sensor_safety.rs`/`sensor_report.rs`/`sensor_mock.rs`) and by
  the `expander_audit_never_writes_any_register` test.
* **Zero UART writes in `--passive`** (the default mode): it only opens the Sensor UART at each
  known baud (115200 firmware, 38400 bootloader) in turn and listens, decoding through the real,
  unmodified `opensleep::common::codec::PacketCodec<SensorPacket>`.
* **`--ping`** may send `SensorCommand::Ping` (firmware baud first, then bootloader baud), and
  nothing else -- never `JumpToFirmware`, never any command that changes Sensor's operating mode.
* **`--discover`** implements upstream's own Ping / JumpToFirmware discovery sequence (firmware
  Ping first; only if silent, bootloader Ping; only if bootloader responded, exactly one
  `JumpToFirmware` followed by a re-ping at firmware baud), but **never starts the normal Sensor
  `CommandScheduler`** and never sends `EnableVibration`, `SetAlarm`, `EnablePiezo`,
  `SetPiezoGain`, `SetPiezoFreq`, `ProbeTemperature`, or any presence-calibration command --
  `sensor_safety.rs`'s `SensorProbeAction` enum has no such variant, so those commands are not
  merely disallowed by a runtime check, they are unrepresentable in this binary at all. A
  `--query-info` flag, usable only after a confirmed firmware-mode Ping, additionally permits
  exactly two read-only queries already present in upstream `SensorCommand`:
  `GetHardwareInfo`/`GetFirmwareHash`.
* **`--audit-expander`** reads the PCAL6416A registers (0x00-0x07) and reports them in hex and
  binary, but never writes any of them -- in particular, registers `0x02`, `0x06`, and `0x07`,
  which the Frozen investigation proved are sensitive (bit 1 of port 0 is Frozen's reset line, and
  whole-register writes on `0x06`/`0x07` previously broke the reservoir/capwater indicator), are
  never written by this command in this version.
* **Port-0 bit 0's function was unproven as of revision 19 and remains unproven** -- revision 20
  adds an explicit, opt-in experiment to test one specific hypothesis about it (see the next
  subsection). Outside that experiment, `sensor-probe` still does not assume bit 0 is a Sensor
  reset/enable line, still never pulses it, and still never calls
  `opensleep::reset::ResetController` or the old four-register reset sequence. If Sensor stays
  silent after ordinary UART discovery, this stops and reports the evidence
  (`overall_result: "uart_silent"`, explicitly documented as not proof of a hardware fault) rather
  than guessing at a reset line.
* Never opens Frozen's UART (`frozen_port`) and never references Frozen's transport/command types,
  **except `--combined-narrow-subsystem-init`'s own Ping-only verification step** (revision 21, see
  its own subsection below) -- checked by the `sensor_probe_never_touches_frozen` guardrail test in
  `main.rs`, which now describes that one exception precisely rather than a blanket ban, and by the
  report's own `frozen_uart_writes`/`frozen_uart_opens`/`frozen_port_never_opened` counters (always
  `0`/`0`/`true` for every other mode; `--combined-narrow-subsystem-init` is the only mode where
  `frozen_uart_opens` becomes `1` and `frozen_port_never_opened` becomes `false` -- `frozen_uart_
  writes` stays `0` even there, since that step never sends an *actuating* Frozen command).

### Revision 20: `--enable-suspected-sensor-line` -- an experimental, opt-in hypothesis test

Real hardware evidence narrowed the candidate Sensor enable/reset-release/power-enable line to one
specific bit. On this MT8365 Hub, `/proc/tty/driver/serial` shows `ttyS0`/`ttyS1`/`ttyS2` are all
real, independently-addressed `ST16650V2` MMIO UARTs (`ttyS3` is a `serial8250` placeholder with no
real MMIO/IRQ); `ttyS1` is Frozen's UART, experimentally proven; `ttyS2` is the only other real UART
and the strongest remaining Sensor candidate. Every plain `sensor-probe` invocation (`--passive`,
`--ping`, `--discover`, at both known baud rates) against `ttyS2` shows transmitted bytes but zero
RX -- consistent with a powered-off or held-in-reset Sensor MCU, not with a wrong port. Separately,
upstream OpenSleep's own reset sequence configures register `0x06` to `0xFC` (bits 0 and 1 both
outputs) and keeps register `0x02` bit 0 HIGH throughout -- never pulsing it low -- while this
fork's own proven narrow Frozen-only initialization leaves register `0x06` at `0xFD` (bit 0 still an
input; only bit 1 configured as an output). **Only bit 0 differs between the two initialization
paths, and upstream never drives it low.**

`--enable-suspected-sensor-line` tests this specific, narrow hypothesis -- configure bit 0 as an
output, driven HIGH, and nothing else -- without asserting it is correct:

* **Opt-in only, never implied.** `--passive`, `--ping`, `--discover`, and `--query-info` never
  imply it; every one of those modes keeps its exact revision-19 zero-I2C-write behavior unless this
  flag is also passed. `determine_mode`'s mode selection is completely unchanged; this flag only
  decorates whichever mode was already selected.
* **Exactly two I2C writes, both narrow read-modify-writes, never a pulse:** register `0x02`'s
  output latch is set to bit-0-HIGH first (a no-op write if it already reads HIGH -- still issued
  and verified, never skipped, mirroring `pulse_frozen_reset_bit`'s own "never skip a step"
  convention), *then* register `0x06`'s bit 0 is configured as an output. This ordering -- latch
  level before direction change -- mirrors `pulse_frozen_reset_bit`'s own documented reasoning: the
  pin drives the already-intended level the instant it starts being driven, rather than glitching on
  whatever the latch happened to already read. Every value written is computed from what was
  actually read at that step -- never a hardcoded whole-register constant like the historical
  `0xFC`/`0xFF`/`0xFD`. A dedicated, independent helper
  (`i2c::configure_suspected_sensor_enable_high`) implements this -- **not** a reuse of
  `pulse_frozen_reset_bit` (bit 1's helper), specifically so this unproven, experimental code path
  can never affect Frozen's own proven, hardware-validated bit-1 logic.
* **Never LOW, never a pulse, never bit 1, never register `0x07`.** `SUSPECTED_SENSOR_ENABLE_BIT`
  (bit 0) is structurally separate from `FROZEN_RESET_BIT` (bit 1); `configure_suspected_sensor_
  enable_high` only ever computes `original | SUSPECTED_SENSOR_ENABLE_BIT` -- there is no code path
  in it that can produce a LOW target for bit 0. Every write's changed-bit mask is verified (before
  proceeding) to be a subset of `{0x00, 0x01}` -- if any other bit changed, or a readback doesn't
  match what was written, **`sensor-probe` aborts before any Sensor UART probing at all** and
  reports `overall_result: "expander_verification_failed"`.
* **Prints a prominent warning before any write**: `"EXPERIMENTAL: configuring PCAL6416A port-0 bit
  0 as output-high. No pulse will be generated and no other expander bit will be modified."` No
  typed confirmation phrase is required -- the four `--confirm-*`-style interactive gates this
  binary uses elsewhere are for Frozen's active, actuating tests; this is a read-then-narrow-write
  I2C operation with an already-loud log warning, not a new confirmation pattern.
* **Waits 500ms** after both writes before beginning Sensor UART discovery (`SUSPECTED_SENSOR_
  ENABLE_SETTLE`), then mirrors upstream's own discovery ordering exactly: bootloader baud (38400)
  first, listening passively for 1 second before ever transmitting, up to 3 Ping retries; then --
  always, regardless of whether bootloader responded -- firmware baud (115200), same 1-second
  pre-listen and retry budget. This is a *different* ordering from plain `--discover` (which tries
  firmware first): deliberately mirroring upstream's own bootloader-first ordering specifically for
  this experiment, without changing plain `--discover`'s own, already-shipped behavior at all.
  Unsolicited packets (real Sensor firmware, and this binary's own mock, can push telemetry
  interleaved with a solicited response) never consume the Ping retry budget -- the same
  `send_and_wait_for` drain-until-match logic revision 19 already uses.
* **`--passive --enable-suspected-sensor-line`** is the narrowest possible combination: enable the
  line, then send *zero* further Sensor UART writes, just listen at both bauds for
  `--listen-seconds`. The report's `first_rx_after_enable_ms`/`first_decoded_packet_after_enable_ms`
  fields record the elapsed time from the enable sequence completing to the first raw byte/decoded
  packet -- the strongest evidence this experiment can produce of a causal link between the bit-0
  change and any Sensor activity, without this binary ever having sent that MCU a single byte.
* **State is preserved, not blindly restored.** On normal exit, bit 0 is left exactly as the enable
  sequence configured it -- if it really is a Sensor enable line, automatically reverting it would
  immediately disable the Sensor MCU again and make the experiment impossible to interpret. A
  separate, explicit `--restore-suspected-sensor-line` flag (requires
  `--enable-suspected-sensor-line` in the same invocation -- there is no state to restore to
  otherwise; this binary never persists state across separate invocations) restores *only* bit 0 of
  registers `0x02`/`0x06` to the value *this same invocation* captured before enabling, preserving
  every other bit as it exists at restore time (a fresh read, not a blind write-back of the whole
  originally-captured byte). Never automatic.
* **Still never touches Frozen.** `frozen_uart_opens`/`frozen_uart_writes` stay `0` in every code
  path this flag can reach -- checked by the same `sensor_probe_never_touches_frozen` guardrail test
  (which scans the same five `sensor-probe` source files, `i2c.rs`'s new additions included via its
  own dedicated tests) plus a dedicated runtime test
  (`enable_line_never_opens_frozen_uart`).
* **Still cannot send any actuator/config command.** `--query-info` after a confirmed firmware Ping
  still only ever permits `GetHardwareInfo`/`GetFirmwareHash`, gated by the same closed
  `SensorProbeAction` enum revision 19 introduced -- this flag adds a new *I2C* capability, not a
  new UART command vocabulary.

### Revision 21: `--combined-narrow-subsystem-init` -- reproducing only upstream's port-0 startup

Revision 20's bit-0-only experiment left Sensor completely silent at both known baud rates
(`0 bytes RX` at `115200` and at `38400`), and register `0x06` read `0xFE` afterward -- bit 1 (Frozen's
own, already-proven reset line) was still configured as an *input*. Real hardware evidence already
established that Frozen does not operate correctly until bit 1 is configured as an output and
receives its proven assert/hold/release pulse. A separate, critical observation: this Hub's actual
register `0x07` reads `0x77` -- upstream's own global initialization instead writes `0x31` there
unconditionally, and that whole-register write is now a strong candidate for why the old global
reset broke capwater/reservoir-related hardware (see revision 9's history above).

`--combined-narrow-subsystem-init` reproduces *only* the port-0 portion of upstream's own startup
sequence -- bits 0 and 1 of registers `0x02`/`0x06` -- while leaving register `0x07`, and every other
register, exactly as this Hub's own hardware already has it:

* **Opt-in only; not part of normal `--passive`/`--ping`/`--discover` operation**, and cannot be
  combined with `--enable-suspected-sensor-line`, `--restore-suspected-sensor-line`, or
  `--audit-expander` (this mode has its own fixed expander sequence and its own before/after audit;
  refused instantly if combined).
* **Three writes total**, in the same glitch-avoidance order established by
  `pulse_frozen_reset_bit`/`configure_suspected_sensor_enable_high`: register `0x02` first
  (`asserted = original | 0x03` -- both bits 0 and 1 driven HIGH on the output latch, before either
  becomes an output), then register `0x06` (`configured = original & !0x03` -- both bits 0 and 1
  configured as outputs), then, after holding `PULSE_SETTLE` (~100ms, the same duration already
  proven for Frozen's own pulse), register `0x02` again (`released = (fresh read) & !0x02` -- clears
  *only* bit 1, leaving bit 0 asserted HIGH). This is Frozen's own already-proven assert/hold/release
  pulse for bit 1, combined with bit 0 staying HIGH throughout, in the three writes upstream's own
  sequence would need -- not five, which a naive sequential composition of revision 19's and
  revision 20's separate single-bit functions would otherwise produce. A dedicated, independent
  helper (`i2c::configure_combined_narrow_subsystem_init`) implements this -- not a reuse of either
  single-bit function, and not a generalization of them, for the same reason those two are
  independent of each other.
* **Every write's changed-bit mask is verified to be a subset of `{0x00, 0x01, 0x02, 0x03}`** before
  proceeding; a mismatch, or any readback not matching what was written, **aborts before any UART
  probing at all** (`overall_result: "expander_verification_failed"`) -- proven by
  `combined_init_readback_aborts_before_any_uart_probing`.
* **Register `0x07` is never written, and its preservation is proven, not assumed**: a full
  read-only expander audit (`0x00`-`0x07`) is captured both immediately before and immediately after
  the combined I2C sequence, and the report's `combined_reg07_preserved` field is `true` only when
  both reads succeeded and produced the identical value. Register `0x03` is likewise never written.
* **Verifies Frozen is reachable, Ping only.** After a verified expander sequence, opens Frozen's
  UART, drains ~2s of startup traffic, then Pings using `AuditedTransport`'s `Mode::Passive`
  whitelist -- the same whitelist `frozen-passive` itself uses, which structurally forbids an enabled
  `SetTargetTemperature` and `Prime`. A bootloader response is followed by the same already-proven
  bootloader-to-firmware handling `frozen-passive`/`frozen-cool-test` use
  (`frozen_ops::jump_to_firmware_and_wait`). This is verification only: no temperature target is
  ever set, no `Prime` is ever sent, no pump or cooling is ever started, and a verification failure
  never triggers a global reset -- it is simply reported as `frozen_reached_firmware: false`.
* **This is the one deliberate, narrow exception to `sensor-probe` never touching Frozen.** Every
  other mode, and the other four `sensor-probe` source files, are held to the original, unqualified
  ban -- `main.rs`'s `sensor_probe_never_touches_frozen` guardrail test now describes exactly this
  one exception (only `sensor_probe.rs`; only `FrozenLink`/`/dev/ttyS1`; still never a raw
  `FrozenAction`/`FrozenCommand` construction anywhere in that file -- only the two existing,
  already-audited `frozen_ops::ping`/`frozen_ops::jump_to_firmware_and_wait` wrapper functions).
* **Probes Sensor using upstream's own bootloader-first discovery ordering** (bootloader baud
  `38400` first, listening passively for 1 second before transmitting, up to 3 Ping retries; then --
  always, regardless of the bootloader step's outcome -- firmware baud `115200`, same pre-listen and
  retry budget), identical in spirit to revision 20's `--discover` combination, but tracked with its
  own additional evidence: best-effort `/proc/tty/driver/serial` byte counters for `ttyS2` before and
  after the whole run, and `spontaneous_bytes_38400`/`spontaneous_bytes_115200` plus
  `first_sensor_rx_after_init_ms`/`first_decoded_sensor_packet_after_init_ms` relative to when the
  I2C sequence completed.
* **State is preserved, not restored automatically** -- same rationale as revision 20: the intended
  final port-0 condition (bit 0 output HIGH, bit 1 output LOW) is left in place on exit regardless of
  outcome. There is no `--restore` option for this mode in this version.
* **Result vocabulary**: `sensor_firmware_alive_after_combined_init`,
  `sensor_bootloader_alive_after_combined_init`, `sensor_rx_activity_after_combined_init`,
  `sensor_still_silent_after_combined_init` (explicitly not proof of a Sensor hardware failure --
  same framing as every other "still silent" result this tool reports), `frozen_alive_sensor_silent`,
  and the shared `expander_verification_failed`.

### Revision 22: `frozen-hold-start`/`frozen-hold-stop`/`frozen-hold-status` -- persistent, firmware-owned absolute-temperature control

Every prior active mode is a bounded, host-observed session: `frozen-cool-test` runs for a
requested duration and then disables; `frozen-prime-test`/`--release-frozen-only` send `Prime`
once and observe completion. Revision 22 adds a genuinely different shape: a one-shot
*configuration transaction* that sets a fixed target and then gets out of the way, leaving Frozen
firmware to run the target indefinitely on its own -- exactly how stock OpenSleep's own scheduled
`SetTargetTemperature` calls already work (`opensleep::frozen::manager::get_next_command`), just
triggered explicitly by an operator instead of a time-of-day schedule.

* **`frozen-hold-start --target-c <C>` (or `--left-target-c`/`--right-target-c` together) sends one
  absolute target per side, requires an *exact* matching `TargetUpdate(side, enabled=true,
  temp=<requested>)` for each, and exits.** No baseline measurement, no delta computation -- the
  requested Celsius value converts directly to centidegrees and is validated by the new
  `FrozenAction::hold_target` constructor against the *same* absolute 0-45C backstop
  `frozen-cool-test`'s own `--target-c` already used (`safety::validate_absolute_target_centideg`,
  extracted from `enable_cooling` -- one operating-range constant, not two). `--target-c` cannot be
  combined with `--left-target-c`/`--right-target-c`; the latter two must both be supplied together.
* **After both targets are confirmed, this process sends zero further Frozen commands of any kind
  and exits.** No disable, no `SafetyOff`, no independent shutdown guard, no `Drop`-based shutdown
  behavior, no duration timer, no firmware-message interpretation, no pump/TEC/fan observer, no
  target-attainment logic, no host thermal watchdog, and no reaction to priming or
  `tec[...] locked (pump)` messages -- there is no code path left to run once
  `run_start_core` returns, regardless of what happens to the transport afterward (process exit,
  descriptor close, or a UART disconnect), proven by
  `successful_start_sends_nothing_further_after_confirmation_including_after_uart_loss` and
  `messages_and_tec_lock_text_during_confirmation_do_not_affect_the_result`.
* **Never resets a Frozen that is already responsive.** Unlike `frozen-cool-test`/
  `--release-frozen-only` (which always pulse the narrow bit-1 reset on entry), `frozen-hold-start`
  may be adjusting targets on a Frozen a previous `frozen-hold-start` already brought up and is
  actively regulating -- resetting it would interrupt live thermal control. Startup here is
  "probe first, reset only if silent": up to three bounded, reset-free Pings run first
  (`frozen_hold::probe_responsive_without_reset`, `Mode::HoldStart`); only if Frozen never answers
  does this fall back to the already-audited narrow startup/reset mechanism
  (`frozen_startup::start_frozen_narrow`, unmodified, reused exactly as `frozen-cool-test`/
  `--release-frozen-only` already do). `reset_performed` in the report distinguishes the two paths.
  Never reintroduces the historical whole-register PCAL initialization, and never writes register
  `0x07` -- proven for both the responsive (`no_pcal_write_when_frozen_is_already_responsive`) and
  silent-then-reset (`register_0x07_is_never_written_even_when_the_reset_fallback_fires`) paths.
* **Partial-transaction rollback, but only before success is declared.** If Left confirms and Right
  does not, Left is disabled again (best-effort) and the run reports failure
  (`partial_enable_failure_is_rolled_back`). Once *both* targets have been confirmed and success
  printed, automatic rollback is structurally impossible: the function has already returned.
* **`frozen-hold-stop`** Pings first (logging only -- never to justify a reset), then sends the
  disable command for LEFT and RIGHT repeatedly (three attempts with short spacing, then a bounded
  drain window for a further unsolicited confirmation) -- the same repeated-disable-and-confirm
  shape `frozen-cool-test`'s own controlled shutdown uses, reimplemented independently
  (`frozen_hold::disable_both_and_confirm`) rather than calling into `cool_test.rs` directly, since
  unlike that shutdown path this one must never parse firmware message text and must never fall
  back to asserting the I2C reset. Exits successfully only once both sides' disable is confirmed.
* **`frozen-hold-status` is strictly non-controlling**: `Ping`/`GetTemperatures` only
  (`Mode::HoldStatus` permits nothing else -- no `SafetyOff`, no `HoldTarget`, no `Prime`), never
  touches PCAL state, and is safe to run at any time, including while `frozen-hold-start`'s targets
  remain active (`status_sends_zero_control_commands`).
* **New closed action**: `FrozenAction::HoldTarget { side, target_centideg }`, constructed only via
  `FrozenAction::hold_target`, mapped to the same `FrozenCommand::SetTargetTemperature` wire format
  every other enabled target uses -- there is no new opcode, only a new host-side reason to send the
  existing one. Permitted only in `Mode::HoldStart`; refused everywhere else, including
  `frozen-cool-test`, by the same exhaustive per-mode whitelist match every other action already
  goes through.

## What no subcommand ever does, including `frozen-prime-opensleep-init`

* **Never open the Sensor subsystem UART or reference it at all, in any mode, except
  `sensor-probe` itself.** Sensor is a separate physical UART with no bearing on Frozen priming or
  on `capwater`/`flowrate` reporting (both come from Frozen's own firmware messages) -- even
  `frozen-prime-opensleep-init`, which runs the real Frozen manager, the real MQTT client
  construction, and the real LED controller, does not start it. `sensor-probe`'s own section above
  describes exactly what it is permitted to do instead. This is enforced by `guardrail_tests` in
  `main.rs` scanning the diagnostic's own sources at test time: no file outside `sensor-probe`'s
  own five files may reference `opensleep::sensor`, and the full Sensor manager's `CommandScheduler`
  run loop (`sensor::run`) is banned everywhere, `sensor-probe` included.
* Never write to the `0x53` LED controller other than through the real, already-nonfatal upstream
  code path (`frozen-prime-opensleep-init`) or a read-only, nonfatal probe (every other mode).

## What `frozen-passive`, `frozen-cool-test`, `frozen-prime-test`, `emergency-stop`, and `frozen-hold-start`/`frozen-hold-stop`/`frozen-hold-status` never do

* Never load the operator's own saved configuration file, never connect to MQTT, never run the
  Home Assistant integration.
* Never call the real Frozen manager's command-scheduling loop or any profile/scheduled-priming
  logic -- `frozen-prime-test` only ever sends one manually-confirmed `Prime`, nothing resembling
  the daily-scheduled automatic priming stock OpenSleep performs; `frozen-hold-start` only ever
  sends the one manually-requested absolute target per side, nothing resembling the
  time-of-day-scheduled `SetTargetTemperature` calls stock OpenSleep's own manager makes.
* Never install or touch a systemd unit; every run is a single foreground pass, manually initiated
  every time -- priming and holding a target are both never automatic.

These are enforced both by the fact that these modes' own source never references those code
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
