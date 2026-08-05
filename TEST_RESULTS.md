# TEST_RESULTS.md — opensleep-diagnostic

All 91 unit/integration tests in `src/bin/opensleep-diagnostic/` pass, plus the 51 pre-existing
`opensleep` library tests (unmodified, reused as-is) and 0 doc-tests — 142 total, 0 failed. This
was verified twice: once on the host development machine (native target), and again inside the
`messense/rust-musl-cross:aarch64-musl` builder image via `cargo test --locked` under its
built-in QEMU aarch64 runner (the same environment the release binary is built in) — see
`build-report.txt`.

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
14. **Prime can never be constructed or transmitted.**
    `safety::tests::every_frozen_command_variant_is_accounted_for_by_mode`,
    `main.rs::guardrail_tests::prime_and_random_frozen_command_variants_are_never_referenced_as_constructors`.
15. **Random commands can never be constructed or transmitted.** Same two tests as #14.
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

## Command-audit test

`safety::tests::every_frozen_command_variant_is_accounted_for_by_mode` enumerates every
`FrozenAction` this binary can construct (which stand in one-to-one for the `FrozenCommand`
variants that are reachable at all — `Prime`/`Random` have no `FrozenAction` counterpart and so
cannot even appear in the enumeration) and checks which of the three `Mode`s accept each one,
logging the per-mode result. Combined with the whitelist tests above (#1, #2, #13, #14, #15, #16,
#30), this gives an executable, falsifiable version of the "which modes permit it" table in
PROTOCOL_AUDIT.md.

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
