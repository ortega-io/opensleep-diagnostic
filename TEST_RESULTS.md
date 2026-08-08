# TEST_RESULTS.md — opensleep-diagnostic

All 332 unit/integration tests in `src/bin/opensleep-diagnostic/` pass (up from 309; see the
revision note directly below), plus the 51 pre-existing `opensleep` library tests (unmodified,
reused as-is) and 0 doc-tests — 383 total, 0 failed. Verified inside the
`messense/rust-musl-cross:aarch64-musl` builder image via `cargo test --locked` under its built-in
QEMU aarch64 runner (the same environment the release binary is built in) as part of the
diagnostic-v20 release build -- see `build-report.txt`.

## Revision note: add `sensor-probe --enable-suspected-sensor-line`, an experimental, opt-in test
## of the suspected Sensor enable line (PCAL6416A port-0 bit 0)

Real hardware evidence narrowed the candidate Sensor enable/reset-release/power-enable line to one
specific bit: `/proc/tty/driver/serial` confirms `ttyS2` is the only remaining real MMIO UART
besides Frozen's `ttyS1`, plain `sensor-probe` against it shows transmitted bytes but zero RX at
both known baud rates, and upstream OpenSleep's own reset sequence configures register `0x06` to
`0xFC` (bits 0 and 1 both outputs) and keeps register `0x02` bit 0 HIGH throughout -- never pulsing
it low -- while this fork's own proven narrow Frozen-only initialization leaves register `0x06` at
`0xFD` (bit 0 still an input). **Only bit 0 differs between the two initialization paths, and
upstream never drives it low.**

`--enable-suspected-sensor-line` (opt-in; never implied by `--passive`/`--ping`/`--discover`/
`--query-info`) tests this hypothesis in the narrowest possible way: a dedicated, independent
helper (`i2c::configure_suspected_sensor_enable_high` -- deliberately **not** a reuse of
`pulse_frozen_reset_bit`, bit 1's own helper) configures only bit 0 of registers `0x02`/`0x06` as
an output, driven HIGH -- never a pulse, never LOW, never bit 1, never register `0x07`, never a
whole-register constant. Every write's changed-bit mask is verified to be a subset of
`{0x00, 0x01}` before proceeding; a mismatch aborts before any Sensor UART probing at all
(`overall_result: "expander_verification_failed"`). Waits 500ms, then mirrors upstream's own
bootloader-first discovery ordering (`--discover` combination) or, for `--passive`, sends zero
further Sensor UART writes and just listens, recording the elapsed time from the enable sequence
completing to the first raw byte/decoded packet -- the strongest possible evidence of a causal
link. State is preserved on exit, not automatically reverted; a separate
`--restore-suspected-sensor-line` flag (requires `--enable-suspected-sensor-line` in the same
invocation) restores only bit 0, preserving every other bit as it exists at restore time. 23 new
tests (309 -> 332), split across `i2c.rs` (bit-level proofs against `MockI2c`) and `sensor_probe.rs`
(orchestration/report-level integration tests). Full details in SAFETY.md's "revision 20" section
and PROTOCOL_AUDIT.md's new register-level audit table.

Two bugs were caught and fixed during this work, both before reaching a released version:
* A latent guardrail-test gap from revision 19 itself: `cli.rs`'s own top-level doc comment
  (updated when `sensor-probe` was first added) contained the literal substring `` `sensor::run` ``
  in its prose, which the `sensor_subsystem_is_never_referenced_outside_sensor_probe` guardrail
  test's `needle_b` check (banning that literal everywhere except `main.rs`) correctly flagged once
  re-run -- reworded without the literal substring, following the same self-reference-avoidance
  pattern `main.rs`'s own guardrail-test prose already uses.
* A test (`line_enable_discover_tries_bootloader_before_firmware`) initially used the default
  `--observe-seconds` (60), incurring a real 60-second wait once firmware mode was confirmed --
  fixed by setting `observe_seconds = 0` in the test's own args, cutting that single test from over
  60s to well under 1s with no loss of coverage.

## Revision note: add `sensor-probe`, a read-only-for-I2C investigation of the Sensor subsystem
## over its own UART, independent of Frozen

Added a sixth subcommand, `sensor-probe`, establishing reliable UART communication with the Sensor
MCU (presence/piezo/temperature board) and decoding whatever is already available -- deliberately
not attempting presence calibration, piezo configuration, vibration actuation, alarms, or expander
reset pulsing in this version. Five new files
(`sensor_probe.rs`/`sensor_link.rs`/`sensor_safety.rs`/`sensor_report.rs`/`sensor_mock.rs`), none of
which touch any existing Frozen file's logic; `main.rs` gained the new subcommand's dispatch plus
three new/updated source-scanning guardrail tests, and `cli.rs` gained `SensorProbeArgs`. 35 new
tests (274 -> 309):

* **`--passive`** (default): zero UART writes, zero I2C writes. Opens `/dev/ttyS2` (override with
  `--sensor-port`) at each known Sensor baud (115200 firmware, 38400 bootloader) in turn, listens
  for `--listen-seconds` (default 20), and decodes through the real, unmodified
  `opensleep::common::codec::PacketCodec<SensorPacket>` -- never aborting merely because a frame
  doesn't decode (a bad checksum, an unrecognized opcode, or a firmware variant not yet understood).
* **`--ping`**: may send `SensorCommand::Ping` (firmware baud first, up to 3 tries; only if silent,
  bootloader baud, up to 3 more), and nothing else -- never `JumpToFirmware`, never any
  mode-changing command. Still zero I2C writes.
* **`--discover`**: implements upstream's own Ping / JumpToFirmware discovery sequence (firmware
  Ping first; only if silent, bootloader Ping; only if bootloader responded, exactly one
  `JumpToFirmware` followed by a re-ping at firmware baud), but never starts the normal Sensor
  `CommandScheduler` and never sends any actuator/config command -- `sensor_safety::SensorProbeAction`
  is a closed four-variant enum with no such variant to construct, backed by a source-scanning
  guardrail test proving no other file references those `SensorCommand` variants either.
  `--query-info` (usable only after a confirmed firmware-mode Ping) additionally permits exactly two
  read-only queries already present in upstream `SensorCommand`: `GetHardwareInfo`/`GetFirmwareHash`
  -- inspected against upstream's own decoders, not inferred from their names alone (`GetHeaterOffset`
  is deliberately excluded: upstream never decodes a response for it and it is unexercised anywhere
  in the pinned source). Once communication is established, listens for unsolicited traffic for
  `--observe-seconds` (default 60), tallying every `SensorPacket` variant seen and computing
  per-side capacitance/piezo min/max/latest values (left/right channel split cross-checked against
  upstream's own `PresenseManager::update_presence` indexing).
* **`--audit-expander`** (combinable with any mode): read-only PCAL6416A register dump (`0x00`-
  `0x07`, hex and binary), reusing the existing `I2cPort::read_reg` -- this feature's own files
  contain no `write_reg` call at all, so every register, registers `0x02`/`0x06`/`0x07` (the ones
  the Frozen investigation proved sensitive) included, is structurally unwritable here, not merely
  disallowed by convention.
* **Port-0 bit 0's function is deliberately left unproven.** No reset/enable line pulsing of any
  kind is implemented in this version; if Sensor stays silent after UART discovery, this stops and
  reports the evidence (`overall_result: "uart_silent"`, explicitly documented as not a hardware
  failure) rather than guessing. Identifying that line is a separate, future investigation.
* A bug in an early draft was caught before it reached a released version: `try_ping`'s original
  single-`next()`-per-attempt pairing could mistake an unsolicited telemetry packet (which real
  Sensor firmware, and this binary's own mock, can push interleaved with a solicited response) for
  the answer to a `Ping`, or burn through the whole retry budget consuming unrelated packets while
  the real `Pong` sat unread. Fixed with `send_and_wait_for`, which drains and discards anything not
  matching the awaited response type instead of treating it as a failed attempt -- caught by two
  dry-run integration tests (`full_discover_dry_run_reaches_firmware_mode`,
  `query_info_populates_hardware_and_firmware_info_in_dry_run`) that failed under the original
  implementation and pass under the fix.
* Verified against the actual packaged ARM64 binary (`dist/opensleep-diagnostic-aarch64-static`) via
  `qemu-aarch64-static`, not only the development host -- see `build-report.txt`'s smoke-test section.

## Revision note: remove the 900s duration ceiling, add `--side both` for simultaneous dual-side
## operation, and harden the independent shutdown guard for hours-long runs

A 900-second right-side `--firmware-authoritative` cooling test completed successfully (target
reached and maintained, pump/fan/TEC evidence PASS, 0 of 1200 firmware-reported temperature reads
failed, both targets confirmed disabled, verified shutdown, no emergency reset) -- conclusively
demonstrating the former 900-second/15-minute duration ceiling was an artificial host-side test
limitation, not a demonstrated Frozen firmware limitation. This revision:

* **Removed the hard-coded 900s maximum duration entirely**, across the CLI, the safety checks, the
  reporting, and the docs. Every active test still requires an explicit, finite duration -- there
  is no "run forever" mode -- but there is no diagnostic-imposed maximum: a value is only rejected
  for being zero, failing to parse, being unrepresentable as a `std::time::Duration`, or causing the
  monotonic deadline computation to overflow (checked arithmetic throughout, via
  `Instant::checked_add`). New `--duration <DURATION>` accepts human-readable values (`30m`, `1h`,
  `4h`, `8h30m`) via the integer-backed `humantime` crate (never floating-point hours), mutually
  exclusive with the pre-existing `--duration-seconds` (kept for backward compatibility). Neither
  flag given still defaults to 120 seconds. The former `--confirm-extended-test` flag, and the
  duration-based requirement for it, were removed along with the ceiling they existed to gate -- the
  four existing required `--confirm-*` flags are sufficient acknowledgement; a duration above 300s
  now only prints a reminder.
* **Extended `--side` with a `both` value** for simultaneous left+right operation in the same
  bounded test, always requiring `--firmware-authoritative` (the legacy active loop's per-tick
  host-side heuristics are single-side only by design and do not generalize to two independently
  progressing sides -- a deliberate scoping decision, not an oversight). `Side::Both` is never
  itself represented on the wire: Frozen still receives one ordinary `SetTargetTemperature` for Left
  and one for Right, sent back-to-back with no unrelated polling interleaved between the two writes.
  `--target-c` with `--side both` sends the exact same absolute target to both sides (each still
  independently validated against its own measured baseline); `--delta-c` with `--side both` applies
  the same delta independently to each side's own baseline, so the two resulting targets may differ
  slightly. The active phase does not begin observing until *both* sides' enabled `TargetUpdate` is
  explicitly confirmed; if only one side confirms, this is its own terminal condition
  (`partial_dual_side_enable`) -- both sides are immediately disabled, verified, and the run never
  continues with only one side active. A fault on either side (an explicit TEC safety-lock message,
  or that side's enabled target being explicitly lost) stops both sides together.
* **Hardened the independent shutdown guard** (the separate OS process that backstops the main
  process crashing, hanging, or being killed) for runs that can now legitimately last hours. It
  previously only detected the main process *exiting* (its stdin pipe closing). It now additionally
  requires a periodic heartbeat byte written from within the main process's own per-tick active loop
  (every 10s, timing out after 45s of silence) -- a genuinely stuck loop, not just a dead process,
  now triggers the same immediate controlled disable. The guard also runs in its own process group
  (so a SIGHUP delivered to the parent's controlling terminal is never delivered to it) and
  separately consumes SIGINT/SIGTERM/SIGHUP itself in a loop that never exits on any of them -- only
  its own disarm byte or firing ends it, so a disconnecting SSH session can never silently disable
  this safety net.
* **Fixed a `target_reached: true` / `time_to_target_seconds: None` reporting bug** in
  `--firmware-authoritative` mode: `record_fa_temperature_sample` set the boolean but never actually
  recorded the elapsed time. Now measured from the side's own enable confirmation to its own target
  being reached, tracked independently per side (`left_time_to_target_seconds`/
  `right_time_to_target_seconds`) so one side reaching target first can never overwrite or block the
  other's value -- regression-tested by
  `firmware_authoritative_time_to_target_is_populated_when_target_is_reached`.
* **Added the dual-side report fields** item 9 of this revision's spec calls for (`requested_side_mode`,
  per-side baseline/target/confirmed/reached/time-to-target/pump/TEC-current/shutdown-observed
  fields, `independent_guard_activated`) -- populated for `--side both` runs, and populated from
  the requested side alone (the other side's fields left at their default) for a one-side run, per
  the spec's explicit backward-compatibility instruction. "Emergency shutdown: PASS" in the printed
  report is now "Controlled shutdown: PASS" for `frozen-cool-test`, unless the narrow emergency I2C
  reset genuinely fired -- other subcommands' reports are unaffected.
* **Per-minute progress logging** for both the one-side and `--side both` active phases, instead of
  repeating every unchanged reading at INFO level -- useful for tailing a multi-hour log.

New tests (15 total) cover: the 900s ceiling's removal and no replacement ceiling; `--duration`
parsing 1h/4h/8h30m; zero and unrepresentable durations rejected; `--duration`/`--duration-seconds`
mutual exclusivity; the 120s default when neither is given; `--side both` accepted only with
`--firmware-authoritative`; both enable commands sent back-to-back, left before right; both targets
confirmed before active observation begins; `--target-c --side both` producing the identical target
for both sides; `--delta-c --side both` producing independently-computed (and, given the mock's
differing left/right baselines, differing) targets; duration expiry cleanly disabling and confirming
both sides with no emergency reset; and the `time_to_target_seconds` regression fix above. All 6
`guard.rs` heartbeat/deadline/disarm/parent-death tests were also rewritten for the new 3-way
heartbeat/deadline/disarm race, plus 2 new heartbeat-specific tests.

Verified end-to-end on the actual packaged ARM64 binary (not just `cargo test`): all three CLI
examples from this revision's spec (`--side both --delta-c` with `--duration`, `--side both
--target-c` with `--duration`, and backward-compatible `--side left` with `--duration-seconds`) were
run against `dist/opensleep-diagnostic-aarch64-static` under `--dry-run`, and each correctly sent
the expected enable command(s), confirmed the expected target(s), and produced a clean, verified
shutdown with `overall_pass: true`.

## Revision note: full firmware-authoritative cooling tests -- remove the 2.0C delta cap, all
## typed confirmations, the operator questionnaire, and fix a second false firmware-fault positive

A later live left-side run in `--firmware-authoritative` mode *conclusively demonstrated working
cooling, circulation, fan control, TEC operation, temperature reduction, and verified shutdown* --
confirming the pre-enable telemetry race from the previous revision was genuinely fixed. Four
remaining gaps were addressed in this revision, all scoped to `frozen-cool-test`:

* **A second false firmware-fault positive, fixed structurally this time.** Frozen sent `FW:
  [temps] 0 reads failed out of 1200` -- its own healthy status counter -- and
  `--firmware-authoritative` mode's still-present generic fault-keyword scan classified it as
  `explicit_firmware_safety_fault` because the scan matched the bare word `"failed"` anywhere in
  the message. Fixed by removing generic keyword-based fault detection from
  `--firmware-authoritative` mode entirely, rather than adding yet another excluded word to a list
  that keeps growing: an automatic firmware-fault shutdown in that mode now requires a specifically
  parsed, recognized negative state (the same discipline `TecSafetyState` already enforced) --
  every other firmware `Message`, however worded, is observational and nonterminal. New
  `cool_test::parse_temps_health_report` recognizes `"[temps] <failed> reads failed out of
  <total>"` and reports it purely descriptively
  (`temperature_reads_failed`/`_total`/`_ratio`) -- no count is ever itself a reason to stop. The
  legacy active loop keeps its keyword scan (unchanged), with `"[temps]"` messages now also
  excluded there as a narrower, defensive fix for the same real evidence.
* **Fan telemetry corrected from side-scoped to global.** `"FW: [top-fan] <duty> @ <rpm> rpm"` /
  `"FW: [bottom-fan] <duty> @ <rpm> rpm"` name no cooling side at all -- both fans are Hub-wide
  thermal management. Both active loops' "was fan telemetry observed" check previously required the
  selected side's own bracket tag to appear in a fan message, which it structurally never could.
  New `cool_test::parse_fan_report` is never side-scoped; `--firmware-authoritative` now reports
  `top_fan_activity_observed`/`latest_duty`/`latest_rpm`/`max_rpm` and the `bottom_fan_*`
  equivalents, and its "no fan telemetry" warning fires only when *neither* fan produced any.
* **The fixed 2.0C host-side cooling-delta maximum was removed entirely**, not replaced with
  another guessed cap. `safety::FrozenAction::enable_cooling` now only requires a positive, finite
  delta and a resulting target within the existing, unchanged conservative 0-45C absolute backstop
  -- Frozen firmware remains responsible for PID regulation, TEC current protection, thermal
  protection, and target maintenance, exactly as `--firmware-authoritative` mode already assumed.
  A resulting delta above 2.0C now requires the auditable `--confirm-large-temperature-delta`
  acknowledgement (never itself a new maximum). New `--target-c` sets an absolute target directly,
  mutually exclusive with `--delta-c`, validated against the measured baseline once known --
  checked in `run_core` after baseline collection, distinct from `--delta-c`'s own early check in
  `run()` (which can run before any hardware access, since that delta is known from the CLI args
  alone). The 1.0C default is unchanged and was never the maximum.
* **Every interactive typed confirmation phrase was removed**: `I CONFIRM THE WATER LOOP IS
  CONNECTED AND FILLED`, the second phrase naming the selected side, `RESERVOIR INDICATOR IS STILL
  WORKING`, and `RUN EXTENDED COOLING TEST FOR UP TO 15 MINUTES`. The four required `--confirm-*`
  flags remain; `--confirm-extended-test` (duration above 300s) and
  `--confirm-large-temperature-delta` (delta above 2.0C) replace the phrases that used to gate
  those two specific situations, checked purely from the command line. New `--non-interactive` is
  the explicit, documented flag for this behavior (in effect the only behavior now, since there is
  no more interactive alternative to fall back to). The post-run operator questionnaire
  (`prompt_observations`, `"Pump heard/felt?"` etc.) was deleted outright -- `frozen-cool-test`'s
  report now always includes `"operator observation: not collected"` for anything this tool cannot
  verify electronically, rather than pausing for input or letting a missing answer make the run
  look like it failed. New `--operator-note` attaches optional free text; it is never required and
  never prompted for.

8 net new tests (259 total, up from 251): the exact live-hardware `[temps]` false positive
(`temps_zero_reads_failed_is_healthy_not_a_fault` and an end-to-end
`temps_and_fan_telemetry_do_not_stop_firmware_authoritative_cooling_and_are_reported` test that
also proves fan telemetry is recorded correctly), fan-format parsing
(`fan_report_parses_duty_and_rpm_with_no_side_identifier`,
`fan_report_never_matches_the_other_fan_or_unrelated_messages`), no fixed delta maximum
(`large_delta_without_confirmation_flag_is_refused`, `large_delta_is_accepted_with_the_confirmation_flag`,
`target_c_resulting_in_a_large_delta_is_refused_post_baseline_without_the_confirmation_flag` in
`cool_test.rs`, plus `cooling_delta_has_no_fixed_maximum_at_construction`,
`cooling_delta_still_respects_the_conservative_absolute_backstop`,
`cooling_delta_cannot_be_zero` in `safety.rs`), and a non-interactive completion proof
(`non_interactive_run_never_blocks_on_a_confirmation_phrase`). Every duration/confirmation test that
referenced a removed phrase constant was updated to check the corresponding flag instead
(`durations_above_three_hundred_seconds_require_the_extended_confirmation_flag`,
`duration_at_or_below_three_hundred_seconds_never_needs_the_extended_confirmation_flag`,
`correct_extended_duration_flag_lets_the_run_proceed_past_that_gate`); the obsolete reservoir-phrase
test was replaced with `target_c_resulting_in_a_large_delta_is_refused_post_baseline_without_the_confirmation_flag`,
exercising the one remaining post-baseline confirmation gate directly.

## Revision note: add `--firmware-authoritative`, an optional narrower active-phase mode

A live cooling test enabled the selected side successfully -- the pump was commanded, the solenoid
opened, and the operator physically heard water flowing -- but the run stopped seconds later with
`pump_startup_failure`. Root cause: three `"pump[left] off @ 0.000000V"` reports were already
sitting in the host's own read buffer from *before* the enable command was even acknowledged; the
active loop had no way to distinguish that stale, pre-enable evidence from a genuine post-enable
failure. A host-side telemetry race, not credible evidence the pump had failed -- the same class of
bug (the diagnostic second-guessing Frozen firmware on incomplete or misordered telemetry) as the
TEC false positive documented below, this time in the pump-confirmation path.

Rather than patching the legacy active loop's heuristics again, this revision adds an entirely
separate, opt-in active-phase mode -- `--firmware-authoritative` -- alongside the legacy loop,
which is otherwise completely unchanged (every existing test in this file, unmodified, still
passes). See SAFETY.md's own new section for the full operator-facing rationale; summary of what's
new here:

* **Enable confirmation now waits for the *specific* enabled `TargetUpdate`**, not merely "some
  reply arrived to the enable command" (the legacy loop's `send_result.is_ok()` shortcut, which is
  exactly the gap that let already-buffered pre-enable telemetry look like proof of enablement).
  Anything else observed while confirming is tagged pre-enable: recorded in the raw report, never
  actioned as active-phase pump/TEC/fan/target state. A genuine implementation bug was caught by
  this revision's own regression test while building this: the *original* enable send's own
  single-packet reply can itself already *be* the real `TargetUpdate` (the normal case, when no
  stray telemetry happens to be queued ahead of it) -- the first draft discarded that reply and
  waited for a second packet that would never arrive, timing out and misreporting
  `enabled_target_state_explicitly_lost`. Fixed by checking that original reply first.
* **The legacy loop's host-side heuristics are all disabled in this mode**: pump-startup-not-
  confirmed, the communication watchdog (5s), the temperature watchdog (20s)/startup grace (15s),
  and the generic firmware fault-keyword scan's grace-gated substring behavior. Reaching the
  computed target no longer stops the test either -- it's logged, and Frozen keeps maintaining it
  for the rest of the requested duration.
* **A small, closed set of legitimate automatic stop conditions replaces them**: duration expiry,
  operator abort, a signal, an explicit TEC safety lock (`"unsafe, locking"`/exactly `"locked"`,
  same word-exact parser), an explicit recognized firmware safety-fault message, the enabled target
  being explicitly lost, a fatal UART error, an internal error, and one remaining communication
  check -- no valid packet of *any* kind for 30 seconds (`FA_COMMUNICATION_SILENCE_LIMIT`), a single,
  deliberately much longer threshold than the legacy loop's 5s/20s watchdogs.
* **A second, previously undocumented pump-message format was captured from the same incident**:
  `"[pump-left] slow=>6.500000"` / `"[pump-left] default=>9.000000"` -- a dash-and-arrow
  pump-*command* format, distinct from the existing bracket-and-`@` status format. New
  `is_pump_command_event` recognizes it as positive pump evidence. Its `"default"` value was a
  second real trigger for the word-exact fault-keyword fix from the previous revision (`"fault"` is
  a literal substring of `"default"`) -- confirmed still correctly non-triggering.
* **An independent shutdown guard** (new `guard.rs`, and a hidden `internal-cool-test-guard`
  subcommand), armed only once the target is confirmed enabled and only for a real (non-dry-run)
  run: re-execs the packaged binary as a genuinely separate OS process -- deliberately not a thread,
  since an in-process construct shares fate with whatever it's meant to protect against (a panic
  that unwinds past `main`, a segfault, an OOM kill, `kill -9`). It races an arm timer (requested
  duration + 30s grace) against reading a disarm byte from its own stdin pipe; if the main process's
  own verified shutdown never disarms it in time, it opens the real Frozen UART/I2C itself and runs
  the exact same `run_cool_test_shutdown` every other path in this tool uses.
* **Unchanged**: the default duration (120s), hard maximum (900s), the 2.0C delta cap, all four
  required `--confirm-*` flags, both typed confirmation phrases, baseline collection/validation, and
  the extended-duration confirmation above 300s.

7 net new tests (251 total, up from 244): the exact pre-enable race replayed end to end
(`pre_enable_pump_off_telemetry_does_not_stop_firmware_authoritative_cooling`), TEC unsafe-locking
still triggers immediate shutdown in this mode
(`tec_unsafe_locking_triggers_immediate_shutdown_in_firmware_authoritative_mode`), and 5 tests
against the independent guard's pure fire-or-stand-down decision logic
(`guard::tests::*` -- disarm-byte-wins, any-byte-counts-as-disarm, pipe-closing-means-parent-gone,
arm-expiry-means-fired, and a race between disarm and expiry). See "What is and isn't covered by
automated tests" in `guard.rs`'s own module docs, and the known-gaps section below, for what the
independent guard's *real* process-spawning/hardware-opening path could not be exercised by
`cargo test` -- the same category of gap `frozen-prime-opensleep-init`'s real (non-mocked) path
already has, for the same underlying reason (no real hardware, and in this case no real re-exec'able
packaged binary, available in a test environment).

## Revision note: the fixed TEC-lock parser still aborted -- a caller bug and a watchdog mismatch

Even after revision 14 fixed the substring-matching bug in TEC-lock detection, a live left-side
cooling test still shut down immediately on `FW: tec[left] safe, unlocking`. Two further,
independent bugs were found from that single symptom, both now fixed with much better shutdown
diagnostics added specifically so a third incident like this is never ambiguous from the logs:

* **The real cause: a watchdog clock mismatch, not the TEC message at all.** The incident's
  captured timing (target enabled, TEC current and `"safe, unlocking"` both received two seconds
  later, shutdown beginning at that same instant) is exactly `STALE_TELEMETRY_LIMIT` (2s) -- a
  clock refreshed only by unsolicited `TemperatureUpdate`, shorter than this firmware's own
  unsolicited-push cadence (~10s, per revision 13's own finding). The TEC message and the shutdown
  were simply coincidentally close in the log. Fixed by replacing the single clock with four
  independent ones and three separate, real-hardware-sized limits: `ANY_VALID_RX_LIMIT` (5s, any
  decoded packet), `TEMPERATURE_FRESHNESS_LIMIT` (20s, once a first active-phase temperature
  sample has been seen), and `ACTIVE_STARTUP_GRACE` (15s, before the first one has). New
  `StopReason` variants `CommunicationWatchdogExpired`/`TemperatureWatchdogExpired`/
  `TemperatureStartupGraceExpired` replace `TelemetryStale` in `frozen-cool-test`'s own active
  loop (kept in the shared vocabulary -- `frozen-prime-test` still uses the original constant and
  is unaffected, having not been shown to share this firmware's cadence problem).
* **A synchronous `GetTemperatures` response is no longer "raw evidence only" during the active
  phase.** It was already used for baseline collection (revision 13) but silently ignored once the
  active phase started, even though it's the same signal the temperature watchdog above depends
  on. A new shared helper, `record_active_temperature_sample`, now processes it identically to the
  unsolicited push (history, min/max, `evaluate_tick`, target-stability) -- for both the original
  27-byte reply and this firmware's 14-byte reply, the latter recovered via
  `frozen_compat::CompatFrameScanner` during the active phase too, not baseline only.
* **The active loop tried the safety-state parser on every TEC-tagged message unconditionally**,
  including plain current readings (`"FW: tec[left] current: 11.364773 A"`) -- which
  `parse_tec_safety_state` correctly classified as `Unknown` (no lock-related word present), but
  the caller then logged as `"unrecognized TEC safety-state message"` on every single reading.
  Fixed by routing TEC-tagged messages by type: `parse_tec_current` is tried first, and only if
  that doesn't match does the safety-state parser run at all.
* **`TecSafetyState::is_fault()`/`is_safe_transition()` were removed entirely.** Even with a
  correct parser, the caller's own control flow is what actually caused this incident's shutdown
  in an earlier draft (`if parse_tec_state(msg).is_some() { break; }`-shaped code). Every call site
  -- including this file's own tests -- is now required to write an exhaustive `match` over all
  five `TecSafetyState` variants, so a future positive state can never again be silently folded
  into "terminal" by a boolean convenience method.
* **A second, previously undiscovered substring bug, found by this fix's own regression test**:
  `"fault"` is a literal substring of `"default"`, and `"FW: pump[left] default @ 9.000000V
  0.200000A"` (a pump reverting to its default drive state -- real vocabulary, confirmed by this
  incident's own captured timeline) was being misclassified as `FirmwareFaultMessage` by the
  generic fault-keyword scan's plain `contains("fault")` check. Fixed the same way as the
  `"locked"`/`"unlocked"` case: `"fault"` is now matched word-exact via
  `WORD_EXACT_FAULT_KEYWORDS`, alongside `"locked"`.
* **Every controlled shutdown now logs `"beginning controlled shutdown: stop_reason=<code>"`** from
  inside `run_cool_test_shutdown` itself -- the sole function every exit path (active loop,
  baseline-collection interruption, every preflight refusal) calls before returning, so there is no
  path into shutdown without an assigned, logged reason. New `stop_reason_code` field
  (`cool_test::stop_reason_code`, a stable underscore_case identifier distinct from the existing
  human-readable `stop_reason` prose) added to `CoolTestResults` and wired into text, JSON, and CSV.
* **`frozen-cool-test --dry-run`'s shared mock device** now also pushes the exact captured TEC
  current/`"safe, unlocking"` sequence once a side is enabled, so this positive-state handling is
  exercised by the actual packaged ARM64 binary under `qemu-aarch64-static`, not only `cargo test`
  (`frozen-prime-test`'s dry-run is unaffected -- it never enables a target).
* **Unchanged**: default duration (120s), hard maximum (900s), and the 2.0C delta cap.

4 net new tests (244 total, up from 240): the exact captured incident timeline replayed end to end
(`incident_timing_sequence_does_not_trigger_any_watchdog`, which independently caught the
"fault"/"default" bug above), a temperature-watchdog-with-ongoing-Message-traffic case proving the
two watchdogs are genuinely independent, and both directions of the new "fault"/"default" fix. Two
existing tests were corrected to their new, more precise expectations
(`unsafe_locking_message_triggers_controlled_shutdown` now expects the split `TecUnsafeLocking`
reason; the renamed `complete_silence_during_active_phase_triggers_communication_watchdog` now
expects `CommunicationWatchdogExpired`, since its device goes genuinely silent, not merely
temperature-silent). All `TecSafetyState`-related tests were rewritten to use an exhaustive `match`
helper rather than the removed boolean methods, matching the caller-discipline fix above.

## Revision note: fix a false TEC-lock abort; extend the active phase to 15 minutes

A live left-side cooling test successfully enabled the target, reached active hardware control
(`FW: tec[left] current: 11.402626 A`), and then aborted on `FW: tec[left] safe, unlocking` --
logged as `firmware reported the selected TEC locked`. This is a false positive: "safe, unlocking"
is a positive safety transition (the interlock reporting it is safe to run), not a lock/fault.

* **`cool_test::TecSafetyState`/`parse_tec_safety_state`** replace the previous
  `contains("tec") && contains("lock")` check (which also matches `"unlocking"`/`"unlocked"`, both
  of which contain the substring `"lock"`) with word-tokenized classification: split on
  non-alphanumeric characters, then an exact-token match against `"unlocking"`/`"unlocked"`/
  `"locking"`/`"locked"`. Only `UnsafeLocking` (`"unsafe, locking"`) and the exact word `"locked"`
  abort (`TecLocked`); `SafeUnlocking`/`Unlocked` set `selected_tec_safety_passed` and let the
  active phase continue; anything else classifies as `Unknown` and is logged, never a fault. The
  identical substring trap independently existed in the generic fault-keyword scan's flat
  `contains("locked")` check (`"locked"` is a literal substring of `"unlocked"`) and was fixed the
  same way -- word-exact match for that one keyword, every other keyword unchanged.
* **`cool_test::parse_tec_current`** parses `FW: tec[<side>] current: <amps> A` and tracks
  first/min/max/last plus a sample count (`selected_tec_current_*` report fields) -- purely
  descriptive, never independently classified as safe/unsafe (no validated hardware-specific
  current threshold exists; Frozen firmware remains the sole authority on its own internal current
  safety).
* **Active-phase duration**: hard maximum raised from 300 to **900 seconds (15 minutes)**; default
  stays 120s; the 2.0C delta cap is unchanged. Requesting more than 300 seconds requires an
  additional, exact confirmation phrase (`RUN EXTENDED COOLING TEST FOR UP TO 15 MINUTES`, checked
  early, before any I2C/UART access) and prints a reminder that the operator must remain present
  for the whole run and continuously monitor for leaks, a burning smell, abnormal pump noise, loss
  of circulation, or unexpected heating.
* **Target-reached is now confirmed stable, not single-tick**: the selected side's temperature
  must stay at or below the computed target for `TARGET_STABLE_CONFIRM_WINDOW` (5s) before the
  active phase actually stops -- a lone noisy or fast-settling sample is no longer sufficient, and
  the TEC is never kept enabled merely to consume the rest of the requested duration once
  stability is confirmed. `time_to_target_seconds` records when the target was first reached
  (distinct from the total active duration, which includes the confirmation window).
* **Ctrl+C/SIGTERM/SIGHUP now reach controlled shutdown from baseline collection onward, not only
  the active phase**: `wait_for_termination_signal` is now raced via `tokio::select!` in the
  baseline loop too (baseline can now take up to 60s -- see the previous revision). This closes a
  real gap: `tokio::signal::ctrl_c()` only replaces the OS's default "kill immediately" SIGINT
  disposition once it has actually been awaited somewhere in the process; without this, the first
  Ctrl+C during baseline collection would have terminated the process outright, bypassing
  `run_cool_test_shutdown` entirely.
* **New/renamed `CoolTestResults` fields**: `actual_duration_seconds` ->
  `actual_active_duration_seconds`; `selected_side_change_c`/`opposite_side_change_c`/
  `heatsink_change_c` -> `selected_side_temperature_change_c`/`opposite_side_temperature_change_c`/
  `heatsink_temperature_change_c` (exact names now match the fix request). New:
  `extended_test_confirmation_received`, `time_to_target_seconds`, `maximum_heatsink_c`,
  `selected_tec_safety_passed`, `selected_pump_activity_observed`,
  `selected_tec_current_first/min/max/last_a`, `selected_tec_current_samples`,
  `telemetry_watchdog_triggered`, `communication_loss_observed`, `operator_abort_observed`,
  `both_targets_shutdown_confirmed`, `selected_pump_shutdown_observed`,
  `selected_tec_shutdown_observed`. The shutdown-verify window now also watches for pump/TEC
  status messages for the selected side (best-effort, in addition to the primary `TargetUpdate`
  confirmation). Wired into text, JSON, and a new trailing `field,value` summary section in the
  CSV export (the per-sample time-series rows are unchanged).
* **All previously-working behavior verified unchanged** by the existing (still-passing) test
  suite: shared narrow Frozen reset, no `ResetController`, only expander bit 1 modified, reservoir
  confirmation before active cooling, exactly one cooling side enabled, three-times-repeated
  both-side shutdown, no global subsystem reset on normal completion, no raw serial dumps by
  default.

22 net new tests (240 total, up from 218), all in `cool_test.rs`, including: the exact 4 fixture
messages from the fix request (`"safe, unlocking"`/`"unlocked"`/`"unsafe, locking"`/`"locked"`)
proven both at the parser level and end to end through the active loop; the same distinction
proven against the generic fault-keyword scan; 900s accepted and 901s rejected with an explicit
message; the extended-duration phrase gate (required above 300s, never checked at or below it);
early stop confirmed to wait out the full stability window, not a single tick; TEC current
parsing; communication loss (a dropped link) and selected-pump startup failure each triggering
controlled shutdown; and a SIGTERM-specific shutdown test alongside the existing Ctrl+C one.

## Revision note: decode the 14-byte `GetTemperature` reply; fix a premature baseline cutoff

A live run against MT8365 / Frozen firmware v1.4.235 reached application firmware correctly through
the shared narrow reset path, but `frozen-cool-test` refused to enable cooling: baseline collection
requires 5 valid samples, only 4 unsolicited `TemperatureUpdate` pushes arrived before the previous
`BASELINE_MIN_WINDOW * 4` (40s) backstop cut collection off, and every solicited `GetTemperature`
reply logged `Frozen/GetTemperature wrong size: expected 27, got 14` -- this firmware's reply is 14
bytes, not the 27 the unmodified upstream parser requires.

* **New `frozen_compat.rs`**: `decode_get_temperature_14byte` is a narrow, explicitly tag-validated
  decoder for exactly this 14-byte shape (same field layout as `parse_get_temperature`'s own
  documented example, minus the 13 trailing padding bytes only the 27-byte firmware sends -- never
  infers a value from a fixed offset without checking its tag byte first, matching upstream's own
  approach). `CompatFrameScanner` re-runs `PacketCodec::decode`'s own frame-boundary algorithm
  (magic byte, length-prefixed payload, checksum -- reusing `opensleep::common::checksum::compute`,
  not reimplementing it) over raw bytes from `io_logging::LoggingIo`'s existing `RawIoCapture`,
  which sits below `Framed` in the I/O stack and sees every byte regardless of what the codec above
  it does with them -- the only way to recover this frame at all, since `PacketCodec::decode`
  always advances past a checksum-valid frame before attempting `FrozenPacket::parse`, and on a
  parse failure only logs and continues without ever returning the bytes to a caller of
  `Framed::next()`. 13 new tests, including the exact 3 payloads captured from real hardware,
  cross-checked against the paired real `TemperatureUpdate` values where given, plus
  malformed/reordered-tag/wrong-opcode/truncated-payload rejection and multi-frame/split-feed/
  bad-checksum scanner cases.
* **`frozen-cool-test`'s baseline loop now accepts three sample sources**: the unsolicited
  `TemperatureUpdate` push (unchanged), the original 27-byte `GetTemperature` reply (unchanged,
  still decoded by the unmodified upstream parser), and this firmware's 14-byte reply (new, via
  `CompatFrameScanner`). Samples are deduplicated *within each ~1-second poll tick* on an exact
  (left, right, heatsink) match -- a solicited reply and an unsolicited push reporting the same
  underlying firmware reading in the same tick count once, but two genuinely separate ticks that
  happen to read the same stable temperature (expected during a short, stable baseline window) are
  never treated as duplicates of each other. Per-sample validity (sentinel/out-of-range rejection)
  now runs at collection time, before a sample ever counts toward the minimum, so
  `validate_baseline` itself only rejects for "not enough valid samples" or "implausibly unstable"
  -- never merely because a protocol format wasn't recognized.
* **The 40-second backstop is now 60 seconds** (`BASELINE_MAX_WINDOW`), and the stop condition is
  exactly item 5 of the fix request: continue until 5 valid samples span at least 10 seconds, or 60
  seconds elapse, whichever comes first. Reproduced directly as a pure-function unit test
  (`baseline_should_continue_does_not_stop_at_forty_seconds_with_only_four_samples`) rather than a
  real- or virtual-time async test, since the condition itself is what changed.
* **New, concise compatibility counters** (`compat_counters.rs`) replace repeated full-buffer log
  dumps for three other real-hardware quirks observed alongside the 14-byte reply: a 9-byte
  heartbeat-opcode (`0x53`) payload (upstream expects 3), and unrecognized opcodes `0x54`/`0x55`.
  Since the noisy `log::error!` call lives inside the pinned, unmodified `opensleep::common::codec`
  and cannot itself be modified, suppression happens in the existing global `env_logger` format
  closure (`buildinfo::init_logging`, already used by `log_tap` for a similarly-shaped purpose) by
  matching the stable, compile-time-known prefix of each pattern's `PacketError` `Display` text --
  enabled only for `frozen-cool-test`, so every other subcommand's log output is unchanged. The real
  counts are tracked separately and authoritatively by `CompatFrameScanner` (from actual bytes, not
  log text) and reported in `CoolTestResults`.
* **New `CoolTestResults` fields**: `baseline_samples_requested`,
  `baseline_synchronous_samples_decoded`, `baseline_unsolicited_samples_decoded`,
  `baseline_duplicate_samples_discarded`, `baseline_invalid_samples_discarded`,
  `baseline_collection_duration_seconds`, `baseline_left_range_c`/`baseline_right_range_c`/
  `baseline_heatsink_range_c` (stability range per channel), and the four `compat_*_frames`
  counters above.
* **End-to-end proof, not just unit coverage of the building blocks**: a new test
  (`baseline_recovers_entirely_from_14byte_get_temperature_replies_via_raw_capture`) runs a fake
  device that answers every `GetTemperatures` request with only the raw 14-byte reply -- never an
  unsolicited push -- through the full `run_core` preflight, and asserts baseline collection passes
  using only samples recovered via `CompatFrameScanner`. Further new tests prove duplicate
  same-tick readings don't inflate the sample count, and that cooling stays disabled when baseline
  genuinely fails (implausibly unstable readings) end to end.
* **Unchanged, verified by the existing (still-passing) test suite**: shared narrow Frozen reset, no
  `ResetController`, only expander bit 1 modified, reservoir confirmation before active cooling,
  exactly one cooling side enabled, the 1-2C delta cap, three-times-repeated both-side shutdown,
  SIGINT/SIGTERM handling, and no raw serial dumps by default (`--raw-serial-log` still gates them).

32 net new tests (218 total, up from 186): 13 in `frozen_compat.rs`, 5 in `compat_counters.rs`, 2 in
`io_logging.rs` (the new `events_since`/`hex_to_bytes` capture-reading helpers), and a net 12 in
`cool_test.rs` (14 added, 2 superseded -- the old `validate_baseline`-level sentinel/out-of-range
tests moved to the new, earlier `is_valid_baseline_reading` check they now belong to).

## Revision note: rework `frozen-cool-test` onto the narrow startup model; fix an unbounded-write hang

`frozen-cool-test` previously ran this binary's own reimplemented four-register I2C reset sequence
at startup and the shared, always-assert-0x20-reset `safe_stop::run_safe_stop` at shutdown. Both
are replaced:

* **Shared narrow startup.** The pulse-based startup logic (I2C release, boot-message drain,
  Ping/JumpToFirmware retry) was extracted out of `prime_opensleep_init.rs` into a new module,
  `frozen_startup.rs` (`start_frozen_narrow`), and both `--release-frozen-only` and
  `frozen-cool-test` now call the same implementation -- proven directly (not just by source
  scanning) in `cool_test::tests::cool_test_and_release_frozen_only_use_the_same_shared_narrow_startup`.
  `cool_test.rs` never references `ResetController::`/`run_reset_sequence(` -- enforced by a local
  guardrail test (needles require actual call syntax, not a bare mention, since this file's own
  module docs legitimately discuss both names in prose).
* **Cool-test's own narrow shutdown.** `run_cool_test_shutdown` disables both sides over UART
  (three repeated attempts, matching `safe_stop`'s cadence) and performs **no I2C write at all** on
  a normal stop (`DurationExpired`, the new `TargetTemperatureReached`, or a clean
  Ctrl+C/SIGTERM/SIGHUP) -- only falling back to the narrow, bit-1-only
  `i2c::assert_frozen_reset_bit_only` if UART-based confirmation failed *and* the stop reason is a
  genuine fault. Confirmation is read directly from each disable command's own `TargetUpdate`
  reply (the real protocol's actual ack mechanism), not a separate passive listen -- an earlier
  version of this routine waited a flat, wasted window every time because it only listened for an
  *unsolicited* push that the protocol never sends for this case; fixed before release.
* **A third confirmation phrase**, `RESERVOIR INDICATOR IS STILL WORKING`, is now required
  immediately before the cooling target is enabled, matching `--release-frozen-only`'s own
  placement.
* **Duration bounds changed**: default 120s (was 10s), hard maximum 300s (was 30s); baseline
  collection window extended to >=10s (was >=5s). The delta cap (2.0C) is unchanged. The test now
  also stops early once the selected side's live temperature reaches the computed target
  (`TargetTemperatureReached`), reported as `target_reached` in the JSON output.
* **Raw RX/TX debug log lines are now off by default everywhere** (previously any subcommand
  running with `--verbose` printed them, which was extremely noisy) and independent of
  `--verbose` -- `io_logging::LoggingIo` gained an explicit `raw_log_enabled` boolean, defaulted
  `false` on every constructor and checked directly before each `log::debug!` call, never inferred
  from the log crate's own level filtering. `frozen-cool-test` gained the opt-in
  `--raw-serial-log` flag to turn it back on (the only subcommand with this flag in this revision).
* **`CoolTestResults`** (new `Report` field) reports: selected side, requested delta, requested and
  actual duration, baseline/minimum/final left-right-heatsink temperatures, selected/opposite-side
  and heatsink temperature changes, `target_reached`, selected-TEC/left-pump/right-pump activity
  observed, `shutdown_verified`, `emergency_reset_asserted`, reservoir status, stop reason, and the
  startup mode used.

**A genuine, previously-latent hang was found and fixed while testing this revision.**
`FrozenLink::send()`/`send_only()`/`flush()` transmitted with no timeout at all -- only the *read*
side of every exchange had ever had a caller-supplied bound. A real-hardware failure mode (a stuck
or disconnected UART, or -- as reproduced directly in a new test against a non-responsive mock
device during a long retry loop -- a transport whose write buffer fills and is never drained) could
hang this diagnostic forever with no way to recover except killing the process. `link.rs` gained a
`WRITE_TIMEOUT` (3s) applied to every write; this is a safety fix that benefits every subcommand
using `FrozenLink`, not only `frozen-cool-test`.

**A related exit-code bug was found and fixed in the same pass.** `cool_test.rs`'s internal
preflight refusals (an enabled target survived safety-off, baseline validation failed, the computed
cooling target was refused, a confirmation phrase mismatched) never explicitly returned this
binary's usual 30 -- they fell through to the same 0/21/1 computation an active-test outcome uses.
Device/communication-level preflight failures (the I2C pulse didn't verify, Frozen never reached
firmware) correctly remain 20, matching `--release-frozen-only`'s established convention that the
same `StopReason::PreflightRefused` value can map to different exit codes depending on *why* the
run was refused. `finish()` now takes an explicit `exit_code` parameter per call site (matching
`prime_opensleep_init.rs`'s own `finish_release_only` convention) instead of inferring one
internally.

**20 net new tests (186 total, up from 166):** 13 net new in `cool_test.rs` (the suite grew from
43 to 56, including tests proving the shared startup, the register-0x06/0x02-only shutdown
guarantees, the `--raw-serial-log` default and opt-in, `TargetTemperatureReached`, and that
Ctrl+C specifically triggers both-side disable with no I2C write), 4 new in `frozen_startup.rs`
(a wholly new module), and 3 new in `io_logging.rs`; `link.rs`'s existing 6 tests are unchanged in
count but now also exercise the new bounded-write path.

## Revision note: fix `--release-frozen-only` to configure the reset pin as an output before pulsing it

A live run of revision 10's `--release-frozen-only` pulsed register `0x02` correctly (readbacks all
verified, `0xFD → 0xFF → 0xFD`) and Frozen *still* never responded. Register `0x06` (direction/
config) was never touched by that revision. On the PCAL6416A, register `0x06` selects, per bit,
whether a pin is an input/high-impedance (`1`) or an output (`0`); the power-on-reset default is
every bit an input. A bit configured as an input ignores its output-latch value (register `0x02`)
entirely -- so revision 10's pulse changed what the chip *would* drive if bit 1 were an output, not
the physical pin. The original, confirmed-working upstream reset sequence writes register `0x06` to
`0xFC` (configuring bits 0 and 1 as outputs) as one of its first two writes -- this revision's
narrow, bit-1-only analog was missing entirely.

`i2c::pulse_frozen_reset_bit` now does three writes instead of two, in this order: (1) prepares
register `0x02`'s output latch to the asserted level (`asserted = original | 0x02`) *before* bit 1
becomes an output, so the instant the pin starts being driven it drives the already-intended level
rather than glitching on whatever the latch happened to already read; (2) configures only bit 1 of
register `0x06` as an output (`config = original & !0x02`), preserving bit 0 and every other bit;
(3) holds the now-actually-driven asserted level for 100ms, then releases it (`released = asserted &
!0x02`). Every write's target is verified mathematically before it is issued (an `assert_eq!` inside
the shared `read_modify_write_reg` helper, generalized from register-0x02-only to accept either
register), and every write's readback is verified after. Register `0x06` is deliberately never
restored afterward -- the reset line must stay actively driven, not float back to high-impedance --
and register `0x07` is still never written at all.

`ReleaseFrozenOnlyResults` gained `original_register_0x06`/`config_register_0x06`/
`config_readback_register_0x06`/`config_readback_matches`/`bit1_was_already_configured_as_output`,
alongside the existing register-0x02 fields (now describing the output-latch-prep and release
writes specifically, not "assert"/"release" generically).

**4 net new tests (166 total, up from 162), all in `i2c.rs` (`i2c::tests`):**

* `config_register_0xff_configures_bit_1_as_output_target_0xfd` and
  `config_register_0xfc_remains_0xfc` -- the two starting cases explicitly requested (register 0x06
  starting at the power-on-reset default vs. already correctly configured).
* `config_register_sweep_preserves_every_bit_except_bit_1` -- an exhaustive 256-value sweep over
  every possible original register-0x06 value, proving the configuration write can only ever change
  bit 1, and that `bit1_was_already_output` correctly reflects the original state.
* `output_latch_set_to_asserted_before_direction_becomes_output` -- proves the register-0x02 write
  is issued strictly before the register-0x06 write (checked via write-order indices in the mock's
  write log), and that the very first write is specifically the asserted value.
* `pulse_never_writes_register_0x07` (renamed from `pulse_never_writes_registers_0x06_or_0x07`,
  since register 0x06 is now legitimately written once per pulse) -- the same 256-value sweep,
  now asserting exactly three writes per pulse (register 0x02 twice, register 0x06 once) and that
  register 0x07 never appears.

The two starting-case pulse tests (`pulse_from_0xfd_...`/`pulse_from_0xff_...`) and the end-to-end
`prime_opensleep_init.rs` tests were updated in place for the new three-write sequence and field
names, without changing their count. Smoke-tested against the real cross-compiled binary via
qemu-aarch64-static -- see `build-report.txt` for the full account.

## Revision note: fix `--release-frozen-only` to pulse the reset bit instead of one-shot clearing it

A live run of `--release-frozen-only` (shipped in revision 9) found register `0x02` already reading
`0xFD` (bit 1 already low) at the point of release. That revision's `release = original & !0x02`
was therefore a no-op — no write ever changed the register, no edge appeared on the pin, and Frozen
never responded to `Ping`. Release is a *transition*, not a *level*: the real, previously-confirmed
working reset sequence's last two writes are `0x02 <- 0xFF` (assert) then `0x02 <- 0xFD` (release),
a low→high→low pulse, not a single clear.

`i2c::pulse_frozen_reset_bit` replaces `i2c::release_frozen_reset_bit_only` (removed): it always
asserts bit 1 first (`asserted = original | 0x02`), waits 100ms
(`i2c::PULSE_SETTLE`), then releases it (`released = asserted & !0x02`) — both values computed from
what was actually read at each step, never a hardcoded constant — verifying the readback and
re-checking that only bit 1 changed after *each* of the two writes independently. Both writes'
targets are verified mathematically (via an `assert_eq!`, not merely logged) before either write is
issued, in `read_modify_write_reg02` (the shared helper both this function and
`assert_frozen_reset_bit_only` build on). Neither write ever touches registers `0x06`/`0x07`.

The Ping/JumpToFirmware sequence that follows was also hardened based on the same evidence: this
mode now waits up to 2 seconds for boot messages after the pulse, then Pings repeatedly for up to
10 more seconds (tolerating any interleaved startup messages instead of failing on the first
non-`Pong` packet) before concluding Frozen never responded and aborting without ever sending
`Prime`. The `RESERVOIR INDICATOR IS STILL WORKING` confirmation is now asked only once Frozen has
actually reached application firmware, immediately before `Prime` — and its outcome is reported via
a new three-state `ReservoirStatus` (`Confirmed`/`FailedByOperatorObservation`/`Unverified`)
instead of a plain boolean, so a run that aborted before ever asking is never conflated with one
where the operator was asked and said no.

**4 net new tests (162 total, up from 158):**

* `i2c.rs` (`i2c::tests`): `release_frozen_reset_bit_only_*` (5 tests) removed; replaced with 7
  pulse tests -- `pulse_from_0xfd_asserts_to_0xff_then_releases_to_0xfd` and
  `pulse_from_0xff_asserts_stays_0xff_then_releases_to_0xfd` (the two starting cases explicitly
  requested), `pulse_preserves_every_bit_except_bit_1_for_every_possible_original` (sweeps all 256
  possible original values for *both* halves of the pulse), `pulse_never_writes_registers_0x06_or_0x07`
  (same sweep, asserting the write log contains only register-0x02 writes),
  `pulse_duration_reflects_the_settle_wait`, and `pulse_detects_readback_mismatch_on_the_release_half`
  (a stale-readback mock transport proving the mismatch-detection path is reachable, adapted from the
  revision-9 test of the same shape).
* `prime_opensleep_init.rs` (`prime_opensleep_init::tests::release_frozen_only`): the
  capwater-gates-Prime test was removed (capwater no longer gates Prime -- see above); replaced with
  `pulses_correctly_even_when_register_already_reads_0xfd` (an end-to-end complement to the `i2c.rs`
  unit test, starting a full run from the exact register state that broke revision 9) and
  `aborts_without_prime_when_frozen_never_answers_ping` (a duplex pair whose device side is never
  driven, proving the 10-second no-response abort path and that it does not trigger the emergency
  reset). All other release-only tests were updated for the new field names
  (`asserted_register_0x02`/`released_register_0x02`/etc.) and the new `ReservoirStatus` enum.

Smoke-tested against the real cross-compiled binary via qemu-aarch64-static -- see
`build-report.txt` for the full account.

## Revision note: add `--release-frozen-only`, a minimal Frozen release with no global reset

`frozen-prime-opensleep-init` gained a `--release-frozen-only` flag, replacing both the full
upstream reset (`opensleep::reset::ResetController`) and the earlier `--preserve-boot-state` flag
(removed in revision 7) with a third, narrower startup mode. Real hardware evidence: the full reset
does release Frozen, but it also reconfigures I2C expander (`0x20`) registers `0x06`/`0x07` and
leaves the reservoir-fill indicator off and unresponsive afterward. Tracing the reset sequence's
four writes showed only the last one -- register `0x02` from `0xFF` to `0xFD` -- actually releases
Frozen; `0x06`/`0x07` are never involved in that release at all.

`i2c::release_frozen_reset_bit_only`/`assert_frozen_reset_bit_only` implement a narrow,
read-modify-write single-bit operation instead: `released = original & !0x02` /
`asserted = current | 0x02`, both computed from a fresh register read (never a hardcoded constant),
verified via a readback, with the run aborting before ever opening the Frozen UART if the readback
doesn't match or if any bit other than bit 1 differs from the original.

**13 new tests** (158 total, up from 145):

* 5 in `i2c.rs` (`i2c::tests`): `release_frozen_reset_bit_only_clears_exactly_bit_1_and_nothing_else`
  and `assert_frozen_reset_bit_only_sets_exactly_bit_1_and_nothing_else` each sweep all 256 possible
  original register values, asserting bit 1 is the only bit that ever changes;
  `release_frozen_reset_bit_only_never_writes_registers_0x06_or_0x07` and
  `assert_frozen_reset_bit_only_never_writes_registers_0x06_or_0x07` directly satisfy the requirement
  that these operations never write those two registers, by inspecting the mock transport's full
  write log; `release_frozen_reset_bit_only_detects_readback_mismatch` uses a thin wrapper `I2cPort`
  that returns a stale value on readback, proving the mismatch-detection path is actually reachable
  and not just theoretical.
* 8 in `prime_opensleep_init.rs` (`prime_opensleep_init::tests::release_frozen_only`):
  `dry_run_end_to_end_succeeds_via_the_public_entry_point` (full happy path through the public `run()`
  entry point, including the register-0x02 release, Ping/Pong(true), `Prime`, and `"[priming] done"`);
  `dry_run_refuses_without_the_reservoir_phrase`; `full_run_never_writes_registers_0x06_or_0x07_and_changes_only_bit_1`
  (an end-to-end complement to the `i2c.rs` unit tests, asserting the *entire* mock I2C write log for a
  full run is exactly the one register-0x02 release write -- no restore write on normal completion, no
  emergency write since no fault occurred); `distinguishes_done_from_done_because_empty`;
  `refuses_prime_when_capwater_is_unavailable_after_release` (also checks
  `reservoir_sensor_operational_after_release` is reported `false`);
  `jumps_to_firmware_when_frozen_answers_from_the_bootloader` (`Pong(false)` -> `JumpToFirmware` ->
  `Pong(true)`); `aborts_before_opening_frozen_when_the_i2c_read_fails` (confirms the Frozen UART is
  never opened/pinged if the I2C release itself fails); and
  `reservoir_phrase_is_required_even_after_reaching_firmware`.

A new proactive mock Frozen device, `mock::spawn_mock_frozen_device_release_only`, was added for
these tests (and for `--release-frozen-only --dry-run` in production): unlike the existing shared
`mock::spawn_mock_frozen_device` (which paces its priming-completion push across several
`GetTemperatures` polls, tuned for `frozen-prime-test`'s tick-based active loop), this device pushes
every message on its own short timer with no polling required at all -- matching both real Frozen
firmware (which pushes over UART on its own schedule) and `--release-frozen-only`'s own flow, which
never sends `GetTemperatures`.

`main.rs`'s `frozen_action_prime_is_referenced_only_in_safety_and_prime_test` guardrail test was
updated: `FrozenAction::Prime`/`FrozenAction::prime()` may now appear in `prime_opensleep_init.rs`
(this mode's own `Mode::PrimeTest`-based `Prime` send) in addition to `safety.rs` and
`prime_test.rs`. Smoke-tested against the real cross-compiled binary via qemu-aarch64-static -- see
`build-report.txt` for the full account, including the reservoir-phrase-mismatch refusal path
(`exit_code: 30`).

## Revision note: fix Frozen/Sensor UART paths for this Hub variant

A live run on this Hub completed the real subsystem reset and then failed immediately with
`Serial Io(NotFound): No such file or directory`: `frozen-prime-opensleep-init` was calling the
real `opensleep::frozen::run` with the upstream `opensleep::frozen::PORT` constant
(`/dev/ttymxc2`), correct for the MT8365 devkit the pinned upstream source targets but not present
on this Hub, which exposes Frozen at `/dev/ttyS1` instead (still the unmodified upstream 38400
baud). `frozen::run`'s `port` argument is now a locally-defined `FROZEN_UART_PATH` constant
(`/dev/ttyS1`), passed explicitly -- never `opensleep::frozen::PORT`, which now appears in this
file only as the comparison value in a logged override message
(`"Frozen manager UART override: /dev/ttymxc2 -> /dev/ttyS1"`). Nothing about `frozen::run`'s
protocol, wake sequence, or state machine changed -- only the device path handed to it. A new
preflight check refuses to proceed (before touching I2C at all) if `/dev/ttyS1` does not exist.

This revision also **removes the Sensor subsystem entirely** from this mode rather than keeping it
as a best-effort background task: Sensor is a separate physical UART (upstream default
`/dev/ttymxc0`, also wrong for this Hub -- it would need `/dev/ttyS2` if ever retained) with no
bearing on Frozen priming or on `capwater`/`flowrate` reporting, so the surest way to guarantee it
"must not prevent priming" is to never run it at all, rather than run it best-effort and have to
keep proving its failures stay non-blocking. `main.rs`'s `sensor_subsystem_is_never_referenced`
guardrail test (previously carved out for this file) is back to its original, stricter form: no
file, `frozen-prime-opensleep-init` included, may reference `opensleep::sensor`/`sensor::run`.

`OpenSleepInitResults` gained `frozen_uart_requested`, `frozen_uart_opened`, and
`frozen_manager_task_running` fields, and lost `sensor_subsystem_started`/`sensor_subsystem_error`
(no longer meaningful with Sensor removed). `frozen_uart_opened` is inferred by racing the real
manager's future against a 500ms window immediately after starting: a real open failure resolves
near-instantly (an immediate `Err`), while a successful open keeps the future pending for at least
~100ms on its own (`FrozenState::publish_reset`'s MQTT publish, wrapped in a 100ms
`tokio::time::timeout` that this mode's never-polled event loop cannot complete) before reaching
its main loop -- so this specifically does *not* report "started" merely because a task was
spawned, distinguishing spawned from actually opened.

3 new tests: `frozen_uart_path_is_ttys1_not_the_upstream_devkit_default` and
`frozen_run_is_never_called_with_the_upstream_port_constant` in `prime_opensleep_init.rs`, and
`obsolete_devkit_uart_paths_are_never_hardcoded_anywhere` in `main.rs`'s `guardrail_tests` (scans
this binary's entire source, `frozen-prime-opensleep-init` included, for `/dev/ttymxc0`/
`/dev/ttymxc2`/`/dev/ttymxc` as hardcoded literals -- the only legitimate reference to the real
value is the symbolic `opensleep::frozen::PORT` constant in the logged override message, which
does not contain those literal strings in this binary's own source).

**As before, this mode's active-path behavior (a real Ping/Pong exchange, the real capwater/
flowrate check, an actual Prime send) has not been exercised against real Frozen hardware in this
revision either** -- this fix was made from a live run's own reported error text and the pinned
source, not from a fresh hardware run confirming the fix resolves it. Confirm on real hardware
before relying on this revision's active-path claims.

## Revision note: `--preserve-boot-state` replaced with `frozen-prime-opensleep-init`

The previous revision's `--preserve-boot-state` flag on `frozen-prime-test` (which skipped I2C
entirely to avoid resetting the subsystem) has been **removed**. Real hardware evidence showed that
approach was the wrong fix: skipping the reset didn't just avoid touching I2C, it left Frozen in a
state where the reservoir-level (`capwater`) sensor was not reliably operational -- a regression
this project does not want to ship, regardless of the I2C-avoidance goal that motivated it.

In its place, this revision adds a new subcommand, `frozen-prime-opensleep-init`, which performs
the same Prime-once operation through the **real, unmodified upstream OpenSleep initialization and
Frozen manager code** (`opensleep::reset::ResetController::reset_subsystems`, `opensleep::mqtt::MqttManager`,
`opensleep::sensor::run`, `opensleep::frozen::run`) instead of either this binary's own
reimplemented reset/transport (`frozen-prime-test`) or a custom partial reset
(`--preserve-boot-state`). It never touches `safety::AuditedTransport` at all: it steers the real
upstream Frozen scheduler into sending exactly one `Prime` by constructing an in-memory
configuration (`prime` set to "now", temperature profiles empty so targets stay disabled), observes
the real log output that code produces (via a new `log_tap` module -- see its own docs) to detect
`[capwater]`/`[flowrate]` sensor-unavailable messages and the exact `"done"`/`"done because empty"`
distinction, refuses to send Prime at all if capwater is unavailable as a result of its own
initialization, and never asserts the I2C subsystem reset on normal completion or "done because
empty" (only a genuine firmware-reported pump fault does, via this diagnostic's own already-audited
`assert_reset` primitive). See SAFETY.md and `prime_opensleep_init.rs`'s module docs for the full
design rationale and safety-model writeup.

8 net new tests were added (129 → 142 in this file's directory, after removing the 5
`--preserve-boot-state` tests and adding 13 new ones): 8 in `prime_opensleep_init.rs` (preflight
refusals, dry-run behavior and its JSON output, the narrow pump-fault matcher, and the in-memory
`Config` construction -- `away_mode` stays `false` and temperature targets are disabled via an
empty profile instead, since `away_mode = true` would also block the Prime schedule), 4 in the new
`log_tap.rs` (capture/checkpoint/exact-match behavior, including that `"done"` and `"done because
empty"` are never confused), and 1 in the new `confirm.rs` (the interactive-phrase helper extracted
out of `prime_test.rs` so both Prime-sending modes share one implementation). `main.rs`'s
`guardrail_tests` were also rewritten: four tests that previously asserted Sensor/MQTT/the LED
driver/the real Frozen manager are *never* referenced anywhere now assert they are referenced
*only* by `prime_opensleep_init.rs` -- and that even that file never references the real
config-file loader or `rumqttc` directly, since it still builds its own in-memory configuration.

The real `opensleep::frozen::run`/`opensleep::sensor::run` futures turned out not to be `Send`
(both hold a `tokio::sync::watch::Ref` internally), so unlike this binary's other mocked/spawned
tasks, they cannot be `tokio::spawn`-ed -- `prime_opensleep_init.rs` polls them directly via
`tokio::select!` in the same task, exactly the way real `main.rs`'s own top-level `select!` already
does, which is also what makes shutdown "the normal OpenSleep manager path": there is no
`.abort()` anywhere in that file, the real tasks are simply dropped (cancelled) when the function
returns.

Because the real, unmodified upstream code hardcodes real serial ports and I2C devices with no
mock transport to substitute, `frozen-prime-opensleep-init` cannot be exercised against a mock the
way this binary's other `--dry-run` modes are; its own `--dry-run` only validates confirmations/
arguments and skips real initialization entirely. **Its active-path behavior (a real Ping/Pong
exchange, the real capwater/flowrate check, an actual Prime send, and the `"done"`/`"done because
empty"` distinction) has not yet been exercised against real Frozen hardware or verified any other
way** -- only the CLI surface (`--help`, argument/confirmation validation, `--dry-run`'s exit code
and JSON output) has been smoke-tested against the actual cross-compiled binary so far (see
`build-report.txt`), which is how three CLI-surface bugs were caught before this build shipped.
Run this mode against real hardware and update this note with what was observed before relying on
its active-path claims.

## Revision note: `frozen-prime-test` added

This revision adds the `frozen-prime-test` subcommand, which sends `Prime` (opcode `0x52`) exactly
once to fill an empty/partially-filled hydraulic loop. `Prime` is now reachable, but in exactly one
mode (see PROTOCOL_AUDIT.md for the full source audit and the `Prime`-specific whitelist/at-most-
once enforcement design). Item 14 below is corrected accordingly, and a new checklist section maps
`frozen-prime-test`'s own 28-item test requirement to actual tests. 38 new tests were added: 5 net
new in `safety.rs` (the `Prime`/`Mode::PrimeTest` whitelist and at-most-once enforcement -- one
existing test was also renamed to reflect that `prime_count` is no longer structurally always
zero), 1 new guardrail test in `main.rs` (`frozen_action_prime_is_referenced_only_in_safety_and_prime_test`),
and 32 in the new `prime_test.rs`.

## Revision note: active-test preflight correction

This revision corrects the active-test preflight and safety monitoring based on evidence from a
real `frozen-passive` run and closer reading of the exact upstream source (see PROTOCOL_AUDIT.md
for the full account):

* `TemperatureUpdate.error` is a control-loop error term in degrees C, not a fault/status code —
  renamed to `control_error_c` in reports and never gates any decision.
* Baseline collection and active-phase safety monitoring now rely exclusively on the unsolicited
  `TemperatureUpdate` push (opcode `0x41`), not the solicited `GetTemperature` reply (opcode
  `0xC1`), because real hardware sends a 14-byte `0xC1` frame while the reused parser requires
  exactly 27 bytes and so never decodes it.
* `[capwater]`/`[flowrate]` sensor-unavailable firmware messages are recorded as warnings, not
  treated as fatal.
* New evidence-gated active abort conditions were added: pump still reporting off/0V 3s after
  enable, a TEC-locked firmware message, Frozen disabling the target unexpectedly, a generic
  firmware fault-keyword message after a startup grace period, and an operator typing a report of
  a leak/smell/noise (or `ABORT`) during the active phase.
* `frozen-cool-test`'s default duration changed from 15 to 10 seconds for a first test; the hard
  30-second maximum is unchanged.

Mocking approach: `tokio::io::duplex` pairs stand in for the Frozen UART, decoded/encoded with the
real, unmodified `opensleep::common::codec::PacketCodec`/`FrozenCommand` (never a hand-rolled
protocol); `i2c::MockI2c` stands in for `/dev/i2c-1`; `--assume-interactive-phrase`/
`--assume-start-phrase` (hidden, test-only CLI flags — never documented in RUN_ON_POD.md) stand
in for a human typing the two confirmation phrases, while still exercising the real exact-match
comparison logic. `tokio::time::timeout`/`sleep` provide the clock; real signal delivery is
deliberately *not* exercised (see item 19 below).

## Checklist from the safety spec, mapped to actual tests

1. **Passive mode cannot construct or send enabled target commands.**
   `safety::tests::passive_rejects_enabled_cooling_for_either_side`,
   `passive::tests::passive_never_sends_an_enabled_target_command`.
2. **Passive mode can send safety-off commands.**
   `safety::tests::passive_allows_only_the_documented_actions`,
   `passive::tests::passive_sends_safety_off_for_both_sides`.
3. **Passive mode can enter Frozen firmware and decode telemetry.**
   `passive::tests::dry_run_never_touches_real_devices_and_reaches_firmware`,
   `frozen_ops::tests::get_temperatures_solicited_reply_still_decodes_from_the_mock`.
4. **Missing 0x53 never aborts Frozen testing.**
   `i2c::tests::missing_led_controller_is_reported_but_not_fatal`; the dry-run mock's `0x53` read
   is scripted to fail (`i2c::MockI2c::always_succeed`, which despite its name deliberately fails
   the LED-controller read to mirror confirmed hardware) and every passive/cool-test dry-run test
   still reaches `overall_pass`/proceeds, proving it non-fatal end-to-end.
5. **Sensor is never opened.**
   `main.rs::guardrail_tests::sensor_subsystem_is_never_referenced` — scans this binary's own
   source for `opensleep::sensor`/`sensor::run` rather than relying on a runtime check, since the
   absence of Sensor code is a static property, not something observable behaviorally at runtime.
6. **MQTT and config.ron are never loaded.**
   `main.rs::guardrail_tests::mqtt_and_config_ron_are_never_referenced` (same source-scan
   approach, checking for `opensleep::mqtt`, `rumqttc`, `Config::load`, `config.ron`).
7. **Active mode refuses to run without every confirmation.**
   `cool_test::tests::refuses_without_all_confirmation_flags`.
8. **Active mode refuses when stdin confirmation is wrong.**
   `cool_test::tests::refuses_when_interactive_phrase_is_wrong`.
9. **Active mode accepts exactly one side.**
   Structural: `--side` is a `clap::ValueEnum` with exactly two variants (`Side::Left`/`Right`);
   `safety::tests::cool_test_allows_enabled_cooling_only_for_its_selected_side` and
   `cool_test::tests::dry_run_left_only_enables_left_never_right` prove only the selected side is
   ever enabled.
10. **Active mode clamps delta to at most 2.0C.**
    `safety::tests::cooling_delta_above_max_is_rejected_at_construction`,
    `cool_test::tests::max_delta_constant_matches_spec`. Note: this is a **refusal**, not a
    silent clamp — a delta above 2.0C fails the run with a clear error rather than being quietly
    reduced, per SAFETY.md.
11. **Active mode cannot exceed 30 seconds.**
    `cool_test::tests::refuses_when_duration_exceeds_hard_maximum`,
    `cool_test::tests::max_duration_constant_matches_spec`.
12. **Active mode rejects absolute target input.**
    Structural, not a runtime test: there is no CLI flag or `FrozenAction` constructor that
    accepts an absolute target at all (`FrozenAction::enable_cooling` only accepts
    baseline+delta) — see PROTOCOL_AUDIT.md. Nothing to reject at runtime because nothing exists
    to accept it.
13. **Active mode never enables both sides.**
    `safety::tests::cool_test_never_allows_both_sides_enabled_in_the_same_run`.
14. **Prime can never be constructed or transmitted outside `frozen-prime-test`, and at most once
    within it.** (Corrected from an earlier revision, which predated `frozen-prime-test` and
    stated Prime could never be constructed at all -- see the revision note above and
    PROTOCOL_AUDIT.md for the full audit.)
    `safety::tests::every_frozen_command_variant_is_accounted_for_by_mode`,
    `prime_is_refused_outside_prime_test_mode`, `prime_test_mode_allows_prime_exactly_once`,
    `main.rs::guardrail_tests::frozen_action_prime_is_referenced_only_in_safety_and_prime_test`.
    Within `frozen-prime-test` itself, `Prime`'s reachability is exercised end-to-end by
    `prime_test::tests::dry_run_sends_prime_exactly_once`.
15. **Random commands can never be constructed or transmitted.**
    `safety::tests::every_frozen_command_variant_is_accounted_for_by_mode`,
    `main.rs::guardrail_tests::prime_and_random_frozen_command_variants_are_never_referenced_as_constructors`.
16. **Unknown commands fail the transport audit.**
    `safety::tests::emergency_stop_allows_only_the_two_disable_commands` (asserts `Ping`/
    `GetHardwareInfo`/an out-of-mode `EnableCooling` are all rejected by `AuditedTransport::check`
    in `Mode::EmergencyStop`); the opcode backstop (`ALLOWED_OPCODES`) is exercised indirectly by
    every whitelist test since it is checked on every accepted path too.
17. **Loss of telemetry triggers safe-stop.**
    `link.rs`'s `PacketOutcome::Closed` handling + `cool_test::tests::stale_telemetry_during_active_phase_triggers_safe_stop`
    (a mock device that goes silent mid-test) proves the run stops and safe-stop still executes;
    "closed" (immediate loss) and "stale" (no valid sample for >2s) are distinct `StopReason`
    variants (`TelemetryLost` vs `TelemetryStale`) reaching the same safe-stop call.
18. **Stale telemetry triggers safe-stop.**
    `cool_test::tests::stale_telemetry_during_active_phase_triggers_safe_stop` (asserts
    `stop_reason == "telemetry stale for more than 2 seconds"` and `safe_stop.i2c_reset_asserted`).
19. **Ctrl+C triggers safe-stop.**
    **Not exercised with a real OS signal.** Sending a real SIGINT/SIGTERM/SIGHUP to the shared
    `cargo test` process is process-global and could interfere with other concurrently-running
    tests in the same binary, so this suite does not do it. Instead:
    `cool_test::tests::termination_signal_future_does_not_resolve_spuriously` proves
    `wait_for_termination_signal()` does not fire on its own, and the *same* `tokio::select!`
    arm and unconditional post-loop `run_safe_stop` call are exercised by every other active-loop
    test (duration/staleness) above — the code path from "the termination future resolves" to
    "safe-stop runs" is a single, unconditional fall-through with no reason-specific branching,
    so those tests cover the mechanism even though this one doesn't cover the OS signal itself.
    This was manually verified once against dry-run mode during development (Ctrl+C during an
    active-phase dry-run produced the expected `stop_reason` and safe-stop log lines) but that
    manual check is not part of the automated suite.
20. **Timeout triggers safe-stop.**
    `cool_test::tests::active_phase_stops_at_duration_expired_and_still_runs_safe_stop`.
21. **Panic/task failure triggers safe-stop where testable.**
    Implemented via a `catch_unwind` boundary around `evaluate_tick` (a small, pure,
    panic-free-by-design function) in the active loop, isolating the loop from a hypothetical
    future bug there; the surrounding `run_safe_stop` call is unconditional regardless of how the
    loop exited. Not exercised by a test that forces a real panic (there is no panic-injection
    hook in production code to trigger one safely from a test); `evaluate_tick`'s own logic is
    covered directly by `cool_test::tests::evaluate_tick_*`.
22. **Safe-stop sends both disable commands repeatedly.**
    `safe_stop::tests::safe_stop_sends_both_disables_three_times_and_asserts_reset`.
23. **Safe-stop asserts reset at 0x20.**
    Same test, plus `i2c::tests::assert_reset_performs_exactly_one_write`.
24. **A failed safe-stop prevents an overall PASS.**
    `safe_stop::tests::safe_stop_reports_catastrophic_when_i2c_reset_fails`,
    `cool_test::tests::overall_verdict_fails_closed_on_a_bad_safe_stop_even_if_everything_else_passed`.
25. **Component results remain UNVERIFIED without telemetry or operator evidence.**
    `report::tests::component_results_default_to_unknown_not_pass`,
    `cool_test::tests::tec_trend_is_unverified_not_fail_when_no_measurable_drop_occurred`,
    `cool_test::tests::overall_verdict_is_inconclusive_when_actuators_are_unverified_but_nothing_failed`.
26. **JSON clearly separates machine evidence from operator observations.**
    Structural: `Report::operator_observations: Option<OperatorObservations>` is a distinct,
    separately-typed field from `outgoing_commands`/`telemetry_samples`; not a targeted unit test,
    but the type separation itself is the enforcement (there is no code path that merges them).
27. **`emergency-stop` works even when the LED and Sensor are unavailable.**
    `emergency_stop::tests::emergency_stop_works_with_no_uart_link_at_all` (the Frozen link is
    entirely absent, standing in for any subsystem being unavailable) and
    `emergency_stop::tests::emergency_stop_dry_run_succeeds_without_touching_real_devices`;
    `emergency_stop.rs` never references the LED controller or Sensor at all (see item 5/6's
    guardrail tests, which scan this file too).
28. **Dry-run sends no writes.**
    `i2c::tests::dry_run_mock_performs_no_writes_when_only_probed`; every `*_dry_run_*` test in
    `passive.rs`/`cool_test.rs`/`emergency_stop.rs` runs against `MockI2c`/a mocked duplex-pair
    Frozen device that only ever sees in-memory bytes, never a real device path.
29. **Every active path has a bounded execution time.**
    `cool_test::tests::dry_run_completes_with_a_bounded_duration` (asserts wall-clock < 10s for a
    2-second configured active phase); the hard 30-second cap (#11) plus the 2-second stale-
    telemetry limit plus the fixed-count preflight backstop (`BASELINE_MIN_WINDOW * 4` = 20s
    ceiling on baseline collection) together bound every code path structurally.
30. **Enabled actuator commands are impossible outside active mode.**
    `safety::tests::passive_rejects_enabled_cooling_for_either_side`,
    `safety::tests::emergency_stop_allows_only_the_two_disable_commands`.

## `frozen-prime-test` checklist, mapped to actual tests

The safety spec for `frozen-prime-test` gave its own 28-item checklist. Mapped to actual tests
(all in `prime_test.rs` unless noted):

1-4. **Prime is allowed only in `frozen-prime-test`; prohibited in passive/cooling/emergency-stop.**
   `safety::tests::prime_is_refused_outside_prime_test_mode` (loops over all three other modes),
   `prime_test_mode_allows_prime_exactly_once`,
   `main.rs::guardrail_tests::frozen_action_prime_is_referenced_only_in_safety_and_prime_test`.
5-6. **Prime sent at most once; no automatic retry.**
   `safety::tests::prime_test_mode_allows_prime_exactly_once` (transport-layer refusal of a second
   attempt), `prime_test::tests::dry_run_sends_prime_exactly_once`.
7. **Enabled temperature targets cannot be constructed in prime mode.**
   `safety::tests::prime_test_mode_never_allows_an_enabled_target`,
   `prime_test::tests::dry_run_never_enables_a_target`.
8. **All confirmation flags are mandatory.** `refuses_without_all_confirmation_flags`.
9. **Incorrect interactive confirmation is rejected.** `refuses_when_interactive_phrase_is_wrong`.
10. **Duration cannot exceed 60 seconds** (nor go below 5). `refuses_when_duration_exceeds_hard_maximum`,
    `refuses_when_duration_is_below_minimum`, `duration_bounds_match_spec`.
11. **Ctrl+C triggers safe-stop.** `termination_signal_future_does_not_resolve_spuriously` proves
    the mechanism, same caveat as item 19 above (no real OS signal in this suite).
12. **Timeout triggers safe-stop.** `active_phase_stops_at_duration_expired_and_still_runs_safe_stop`.
13. **UART failure triggers safe-stop.** `going_silent_after_prime_triggers_safe_stop` (a fake
    device that acks `Prime` then goes completely silent).
14. **Internal task failure triggers safe-stop where testable.** Same practical limitation as
    `frozen-cool-test` (#21 above): a `catch_unwind` boundary wraps `evaluate_temperatures`, but no
    panic-injection hook exists to force a real panic from a test. `evaluate_temperatures`'s own
    logic is covered directly by `evaluate_temperatures_accepts_plausible_values`,
    `_rejects_out_of_range_water`, `_rejects_heatsink_over_limit`.
15-16. **Safe-stop disables both targets three times and asserts `0x20` reset.** Mode-agnostic
    mechanism, already proven in `safe_stop::tests` (reused, not re-tested per mode).
17. **Failed reset causes a nonzero exit status.** `failed_i2c_reset_causes_a_nonzero_exit_code`.
18. **`0x53` failure remains nonfatal.** `dry_run_completes_despite_the_led_controller_probe_failing`.
19-20. **Sensor UART is never opened; MQTT and the normal config file are never used.**
    `main.rs::guardrail_tests::sensor_subsystem_is_never_referenced` /
    `mqtt_and_config_ron_are_never_referenced` (both scan `prime_test.rs` too).
21-22. **`capwater`/`flowrate` unavailable are logged as warnings.**
    `capwater_and_flowrate_unavailable_are_recognized_as_nonfatal_sensor_messages`.
23. **`control_error_c` does not cause an automatic abort.**
    `evaluate_temperatures_has_no_control_error_parameter_to_gate_on` (structural: the function
    doesn't take the field), `control_error_c_is_reported_but_never_gates_the_run` (end-to-end:
    present in samples, never causes `TemperatureRangeExceeded`).
24. **Machine evidence and operator observations remain separate.**
    `operator_observations_field_is_never_used_by_this_mode`, plus the structural type separation
    (`PrimeOperatorObservations` is its own type, distinct from every machine-decoded field).
25. **Writing Prime alone cannot produce a PASS.**
    `overall_result_is_inconclusive_not_pass_from_command_and_pumps_alone` (dry-run: command sent,
    acked, pump telemetry and "done" observed, but no circulation evidence -> INCONCLUSIVE, not
    PASS) and `direct_firmware_circulation_evidence_produces_overall_pass` (the positive case, with
    a fake device that emits `"FW: water empty -> full"`).
26. **Dry-run performs no hardware writes.** `dry_run_never_touches_real_devices`.
27-28. **Prime-command count exactly one; enabled-target count always zero for a completed run.**
    `dry_run_sends_prime_exactly_once`, `dry_run_never_enables_a_target`,
    `rejected_command_count_is_zero_on_a_clean_run`.

Plus unit-level coverage of every parsing/classification helper:
`prime_action_serializes_to_the_exact_source_evidenced_frame` (ties the whole file to the real
`7E 01 52 B6 2B` frame), `pump_telemetry_parses_voltage_and_current`,
`pump_telemetry_ignores_unrelated_messages`, `pump_fault_message_is_detected_narrowly`,
`solenoid_and_valve_messages_are_detected`, `reservoir_transition_messages_are_detected`,
`priming_stage_text_strips_the_known_prefix`, `flash_locked_is_excluded_from_the_generic_fault_scan`.

## Command-audit test

`safety::tests::every_frozen_command_variant_is_accounted_for_by_mode` enumerates every
`FrozenAction` this binary can construct (which stand in one-to-one for the `FrozenCommand`
variants that are reachable at all — `Random` has no `FrozenAction` counterpart and so cannot even
appear in the enumeration; `Prime` does appear, since `frozen-prime-test` needs to construct it,
but the same test asserts it is accepted in no mode except `PrimeTest`) and checks which of the
four `Mode`s accept each one, logging the per-mode result. Combined with the whitelist tests above
(#1, #2, #13, #14, #15, #16, #30, and the `frozen-prime-test` items 1-7 above), this gives an
executable, falsifiable version of the "which modes permit it" table in PROTOCOL_AUDIT.md.

## New tests added for the corrected active-test preflight/monitoring

* `cool_test::tests::nonzero_control_error_never_rejects_a_sample` / `evaluate_tick_has_no_control_error_parameter_to_gate_on` —
  proves `control_error_c` cannot gate a decision.
* `cool_test::tests::pump_report_detects_running_from_nonzero_voltage`,
  `pump_report_detects_off_from_zero_voltage`, `pump_report_detects_explicit_off_word`,
  `pump_report_ignores_the_other_side`, `pump_report_ignores_unrelated_messages` — pump-message
  parsing.
* `cool_test::tests::tec_locked_message_is_detected`, `flash_locked_is_not_a_tec_lock` — TEC-lock
  detection and its "flash locked" carve-out at the unit level.
* `cool_test::tests::generic_fault_keywords_are_detected`,
  `flash_locked_is_excluded_from_the_generic_fault_scan` — same carve-out for the broader keyword
  scan.
* `cool_test::tests::capwater_and_flowrate_unavailable_are_recognized_as_nonfatal_sensor_messages`.
* `cool_test::tests::frozen_disabling_the_target_unexpectedly_triggers_safe_stop` — a fake device
  that acks the enable command and then proactively pushes an unsolicited `TargetUpdate(enabled=
  false)`, proving `TargetDisabledUnexpectedly` fires and safe-stop still runs.
* `cool_test::tests::tec_locked_message_triggers_safe_stop`,
  `flash_locked_message_does_not_trigger_safe_stop` (regression test for the carve-out),
  `generic_fault_message_triggers_safe_stop_after_the_grace_period` — end-to-end abort behavior
  against a fake device that emits the relevant firmware `Message`.
* `cool_test::tests::operator_reported_leak_aborts_the_active_phase`,
  `unrecognized_operator_input_does_not_abort` — the operator-abort channel, injected directly into
  `run_core` for testability (mirroring the existing `assume_interactive_phrase` pattern) since the
  production path only spawns a real stdin-reading thread when stdin is a TTY.
* `cool_test::tests::dry_run_uses_unsolicited_updates_and_reaches_a_verdict` — confirms `--dry-run`
  now exercises the unsolicited-update-driven path end to end.
* `link::tests::send_only_writes_without_waiting_for_a_reply`,
  `send_only_is_rejected_by_the_whitelist_before_any_bytes_are_written` — the new
  `FrozenLink::send_only` fire-and-forget primitive.

## Known gaps (stated plainly, not hidden)

* Real OS-signal delivery (Ctrl+C/SIGTERM/SIGHUP) is not exercised automatically — see #19.
* A genuine forced panic during the active loop is not exercised automatically — see #21.
* `StopReason::DecodeFailure`/`FatalStatus`/`UnknownNonzeroStatus` are part of the abort-reason
  vocabulary (matching the safety spec's language) but are not constructed by this build, because
  the reused `opensleep` packet codec/parsers do not expose the underlying per-frame decode
  errors or hardware status byte to this binary — see PROTOCOL_AUDIT.md's "known limitation"
  section. This is a limitation of reusing the upstream codec unmodified (as required), not an
  oversight.
* `frozen-prime-test`'s solenoid/valve detection has never matched a real firmware message,
  because no such message has ever been observed in the pinned source or captured logs — see
  PROTOCOL_AUDIT.md. The test suite only proves the keyword scan itself works
  (`solenoid_and_valve_messages_are_detected`), not that it has ever fired against a real device.
* `frozen-prime-test` cannot detect an empty reservoir directly (`capwater` unavailable on this
  hardware) — this is a real, stated hardware/firmware limitation, not a gap in this tool's own
  logic, and is why the operator watching the reservoir is documented as the primary interlock
  (SAFETY.md) rather than this tool inferring emptiness from pump current or any other proxy.
* `guard.rs`'s real entry point (`guard::run`) — opening a real Frozen UART/I2C device and being
  re-exec'd as an actual child process of the packaged binary — is not exercised by `cargo test`:
  `std::env::current_exe()` under `cargo test` resolves to the *test* binary, which has no
  `internal-cool-test-guard` subcommand, and no real hardware is available in a test environment
  regardless. Only the pure fire-or-stand-down decision logic
  (`guard::wait_for_disarm_or_arm_expiry`) is covered by automated tests. This mirrors the same,
  already-stated gap in `frozen-prime-opensleep-init`'s real (non-mocked) initialization path.
