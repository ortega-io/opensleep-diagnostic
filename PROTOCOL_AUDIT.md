# PROTOCOL_AUDIT.md — opensleep-diagnostic

This document is the evidence trail behind `SAFETY.md`'s claims: every command this binary can
transmit, its opcode and serialized frame, which telemetry fields are used and what evidence
supports their meaning, and — critically — which pump/fan/TEC conclusions are **direct** evidence
versus **inferred**.

All source citations are against the pinned upstream commit:

```
OpenSleep base version: 2.0.0
OpenSleep source commit: 29ea3f8f51d208a02b5d2691720157c7ce96c292
```

Nothing in this document describes behavior invented for this tool; every claim below cites the
exact upstream file/function it comes from. Frame encoding is never reimplemented here — every
frame shown was produced by `opensleep`'s own `FrozenCommand::to_bytes()`/`command()` encoder,
exercised directly by this fork's tests.

## Wire framing (reused unmodified)

`src/common/codec.rs` (`PacketCodec`, `command()`), `src/common/checksum.rs` (CRC-CCITT,
`0x1021` poly, `0x1D0F` init). Frame layout: `7E <len> <opcode> [...payload] <checksum_hi>
<checksum_lo>`. This diagnostic reuses `PacketCodec`/`CommandTrait` directly
(`src/bin/opensleep-diagnostic/link.rs`); it never reimplements framing, and `Framed`'s own
internal buffering is what gives this binary "retain partial frames across reads" and "decode
multiple packets per read" for free — see `src/common/codec.rs`'s `Decoder::decode` loop.

**Known limitation, stated plainly:** `PacketCodec::decode` swallows a bad-checksum or unparseable
frame *internally* (`log::error!(...); continue;` inside the same loop) and never surfaces an
`Err` variant to a caller of `Framed::next()`. This binary therefore cannot report a per-frame
"malformed packet" count distinct from "no packet decoded this window" through this API without
reimplementing decoding (which the task explicitly disallows). It reports `malformed_windows` as
always `0` for this reason and relies on the library's own `log::error!` output — visible because
`env_logger` is initialized before any I/O — to surface unknown/malformed frames to the operator.
This is documented, not silently swept under the rug: see `telemetry.rs`'s `PacketStats` doc
comment and `signals.rs`'s `StopReason::DecodeFailure`/`FatalStatus` doc comments.

### Real-hardware finding: the solicited `0xC1 GetTemperature` reply does not reliably decode

A real `frozen-passive` run against this hardware revision captured evidence that Frozen's
solicited reply to `GetTemperatures` (opcode `0xC1`) arrives as a **14-byte** frame, matching the
worked example already present as a source comment on `parse_get_temperature` itself:

```
/// C1 00 01 0A 15 02 0A 0F 03 07 F5 04 09 3A
/// 0  1  2  3  4  5  6  7  8  9  10 11 12 13
```

— but `validate_packet_size("Frozen/GetTemperature", &buf, 27)` in that same function requires
exactly **27** bytes. Every real `0xC1` reply this diagnostic has observed therefore fails
`validate_packet_size` inside the reused, unmodified parser, which (per the "known limitation"
above) is swallowed internally and never surfaces as a usable packet to this binary at all — it is
silently dropped by the codec, not merely logged oddly.

Because of this, `frozen-cool-test`'s baseline collection and active-phase safety monitoring **do
not use the solicited `GetTemperature` reply for any decision**. Both rely exclusively on the
**unsolicited `TemperatureUpdate` push** (raw opcode `0x41`, the same byte as the `GetTemperatures`
command itself — Frozen appears to broadcast this on its own schedule, independent of being
polled), which validates against a 9-byte size that has been observed to decode correctly and
consistently on this hardware. `frozen-cool-test` still sends `GetTemperatures` once per ~1-second
tick (`FrozenLink::send_only`, added specifically so a send is never paired with waiting for one
specific reply) and still preserves/logs whatever `0xC1` frame, if any, happens to decode as raw
evidence in the report — but nothing in the active loop or baseline validation requires it to
succeed. `frozen-passive` is unaffected by this finding: it already stores both solicited and
unsolicited samples and never required the solicited path to succeed for `overall_pass`.

## Commands permitted per mode

| Command | Opcode | Example serialized frame | `frozen-passive` | `frozen-cool-test` | `emergency-stop` |
|---|---|---|:---:|:---:|:---:|
| `Ping` | `0x01` | `7E 01 01 DC BD` | yes | yes | no |
| `GetHardwareInfo` | `0x02` | `7E 01 02 EC DE` | yes | yes | no |
| `GetFirmware` | `0x04` | `7E 01 04 8C 18` | yes (best-effort, after firmware Ping) | yes | no |
| `JumpToFirmware` | `0x10` | `7E 01 10 DE AD` | yes, only if bootloader detected **and** `--allow-firmware-jump` | yes, same gate | no |
| `GetTemperatures` | `0x41` | `7E 01 41 ...` | yes, 1/s during the telemetry window | yes, ~1/s during baseline + active phases, sent fire-and-forget (see the 0xC1/0x41 finding above) | no |
| `SetTargetTemperature(enabled=false)` | `0x40` | see below | yes, both sides | yes, both sides (other side always disabled) | yes, both sides (the only thing this subcommand sends) |
| `SetTargetTemperature(enabled=true)` | `0x40` | see below | **never** | yes, **exactly** the one side selected at the CLI | **never** |
| `Prime` | `0x52` | — | **never reachable**: no `FrozenAction::Prime` exists | **never reachable** | **never reachable** |
| `Random(_)` | any | — | **never reachable**: no `FrozenAction::Random` exists | **never reachable** | **never reachable** |

Disable frame (`enabled=false`, temp field `0x0000`): `7E 05 40 00 00 00 00 <chk_hi> <chk_lo>`.
Enable frame example (`side=Left(0x00)`, `enabled=true`, `temp=3600` i.e. 36.00C):
`7E 05 40 00 01 0E 10 E6 A8` — this exact frame (and its checksum) is asserted byte-for-byte by
upstream's own `frozen::command::tests::test_temp` and `common::checksum::tests::test_checksum`,
reused unmodified by this fork.

### Why `Prime`/`Random` are unreachable, not just "not sent"

`src/bin/opensleep-diagnostic/safety.rs`'s `FrozenAction` enum has exactly seven variants: `Ping`,
`GetHardwareInfo`, `GetFirmware`, `JumpToFirmware`, `GetTemperatures`, `SafetyOff`, and
`EnableCooling`. There is no `Prime` or `Random` variant, no CLI flag, and no conversion path
anywhere in this binary's source that produces `opensleep::frozen::FrozenCommand::Prime` or
`::Random(_)` and hands it to the transport. `safety::tests::every_frozen_command_variant_is_accounted_for_by_mode`
and `main.rs`'s `guardrail_tests::prime_and_random_frozen_command_variants_are_never_referenced_as_constructors`
both make this an executable, falsifiable claim rather than a design intention.

As defense in depth, `AuditedTransport::check` *also* checks the serialized opcode byte against a
fixed allowed set (`0x01, 0x02, 0x04, 0x10, 0x40, 0x41`) before any frame is transmitted — so even
a hypothetical future bug that somehow produced a `Prime` frame through some other path would still
be refused at the transport layer.

### Why "no absolute target" and "no simultaneous both-sides" are structural

`FrozenAction::EnableCooling`'s fields are private; the only public constructor is
`FrozenAction::enable_cooling(side, baseline_centideg, delta_centideg)`, which computes
`target = baseline - delta` and refuses (returns `Err`) if `delta` exceeds `MAX_COOL_DELTA_CENTIDEG`
(200 = 2.0C) or is negative, or if the computed target falls outside a 0–45C backstop. There is no
constructor that accepts a caller-supplied absolute target.

`Mode::CoolTest { side }` is fixed at construction of the whole run's `AuditedTransport` (from the
CLI's single `--side` flag) and `AuditedTransport::check` only allows `EnableCooling` when its
`side` matches that fixed value — so a single process invocation cannot enable both sides even if
it tried, and there is no flag to select "both".

## Telemetry fields used

Source: `src/frozen/packet.rs` (`FrozenPacket`, `FrozenTarget`, `TemperatureUpdate`,
`GetTemperature`), unmodified.

| Field | Packet | Unit (per source doc comment) | Meaning | Used for |
|---|---|---|---|---|
| `left_temp` | `GetTemperature` (solicited, opcode `0xC1`, raw evidence only — see above) / `TemperatureUpdate` (unsolicited, opcode `0x41`, the safety-relevant source) | centidegrees Celsius | left-side water temperature | `TemperatureUpdate` copy: baseline validation, active-phase range/trend checks, CSV `left_water_c`. `GetTemperature` copy: reported only, when it happens to decode |
| `right_temp` | same | centidegrees Celsius | right-side water temperature | same, other side |
| `heatsink_temp` | same | centidegrees Celsius | heatsink temperature | `TemperatureUpdate` copy: active-phase ceiling check, CSV `heatsink_c`. `GetTemperature` copy: reported only |
| `unknown_temp` | `GetTemperature` only | centidegrees Celsius (source: "unknown_temp ... centidegrees celcius") | undocumented 4th channel | reported raw+converted, not used for any safety decision (its meaning is not established) |
| `error` (reported as `control_error_c`) | `TemperatureUpdate` only | source doc comment: "error in deg celcius" | **not** a fault/status flag by this evidence — see below | reported for display only; never gates pass/fail |
| `count` | `TemperatureUpdate` only | wrapping counter | sequence counter | reported only |

### Temperature-unit evidence

`src/frozen/packet.rs` documents `FrozenTarget::temp`, `TemperatureUpdate`'s three temperature
fields, and `GetTemperature`'s four temperature fields as `centidegrees celcius` in source doc
comments (unmodified). `src/frozen/command.rs`'s own `test_temp` unit test constructs
`FrozenTarget { enabled: true, temp: 3600 }` and asserts the serialized bytes are `0E 10` (3600
decimal), consistent with 36.00C as a plausible heating-pad setpoint. Both facts agree, so this
tool divides every raw `u16` by 100 to get degrees Celsius
(`telemetry::centideg_to_celsius`), and documents this rather than assuming it.

### `TemperatureUpdate.error` (reported as `control_error_c`): why it is not treated as a fault code

`src/frozen/command.rs` contains a captured real firmware log excerpt (a source code comment, not
executable): `Temperature update - Left: 2581, Right: 2581, Heatsink: 2362, Error: 8` appearing
immediately alongside `Message: FW: pid[heatsink] 3.062500 0.693750 0.693750 0.000000 0.000000` —
i.e. the "Error: 8" line is logged next to PID-loop debug output, not next to any fault/alarm
text. Combined with the struct field's own doc comment ("error in deg celcius"), the most
defensible reading is that this is a **PID/control-loop error term** (a normal, usually-nonzero
value), not a boolean/enum fault flag.

This has since been confirmed against real telemetry from this hardware: a real `frozen-passive`
run's decoded `TemperatureUpdate` samples consistently reported a value of **9**, throughout, with
no other sign of a fault. Treating any nonzero value as unsafe would make the diagnostic reject
essentially every real reading. Accordingly this tool:

* Reports the raw value in JSON/CSV as `control_error_c` (renamed from an earlier, misleading
  internal name) rather than anything implying "status" or "error code".
* Never gates any pass/fail/abort decision on it — `cool_test::evaluate_tick`, the function that
  decides whether to abort the active phase on a bad sample, does not even take this field as a
  parameter, which is itself the structural proof that it cannot influence that decision.

### Error/status fields that exist but are not exposed by the reused parser

`common::packet::parse_hardware_info` decodes a `(status_code: u8, HardwareInfo)` CBOR tuple and
**discards** `status_code` after logging a warning if nonzero — it is never returned to the
caller. Since this tool reuses that function unmodified (rather than reimplementing CBOR parsing),
it cannot gate on this status byte either. This is why `signals::StopReason::FatalStatus` and
`UnknownNonzeroStatus` exist in the abort-reason vocabulary (matching the safety spec's language)
but are not constructed by this build — see their doc comments in `signals.rs`.

## Baseline/active-range constants and their rationale

* `MIN_WATER_CENTIDEG`/`MAX_WATER_CENTIDEG` = 1500/3500 (15.00C–35.00C): no upstream source
  documents an operational water-temperature range, so this tool uses the conservative
  compile-time range suggested by the task itself, wide enough to include any plausible indoor
  ambient-to-skin-adjacent water temperature, narrow enough to reject a disconnected/shorted
  sensor (which upstream evidence suggests reads as `0` or `0xFFFF`-adjacent sentinel values, or
  wildly out-of-range numbers).
* `MAX_HEATSINK_CENTIDEG` = 4500 (45.00C): same rationale, applied to the heatsink channel during
  the active phase only.
* `MAX_PLAUSIBLE_TICK_JUMP_CENTIDEG` = 300 (3.00C in ~1s): no real water thermal mass can change
  this fast; a jump this large in one ~1-second tick is treated as a sensor fault, not real
  cooling.
* `BASELINE_MAX_SPREAD_CENTIDEG` = 300 (3.00C across >= 5 samples over >= 5s): the baseline must be
  hardware-stable (not still settling, not glitching) before this tool derives a cooling target
  from it.
* `PUMP_CONFIRM_GRACE` = 3 seconds: how long the selected-side pump is allowed to keep reporting
  off/0V (via a decoded firmware `Message`, see below) after the enable command is accepted before
  that is treated as an abort condition. Matches the exact grace period given in the corrected
  safety spec.
* `FAULT_KEYWORD_GRACE` = 2 seconds: how long after the active phase starts before generic
  firmware-fault keywords in a `Message` (see below) are treated as fatal rather than logged only.
  Chosen conservatively, matching `STALE_TELEMETRY_LIMIT`'s magnitude, to avoid mistaking benign
  boot-time firmware chatter right after the enable command for a real fault.

None of these constants are derived from an upstream-documented safe range (none exists in the
pinned source); SAFETY.md states this plainly rather than presenting them as spec-derived.

## Active-phase abort conditions and their evidence basis

Every condition below runs the same shared `safe_stop::run_safe_stop` regardless of which one
fired; see SAFETY.md for the safe-stop sequence itself. All are evaluated inside
`cool_test::run_core`'s active-phase loop.

| Condition | `StopReason` | Evidence basis |
|---|---|---|
| No fresh, valid unsolicited `TemperatureUpdate` for > 2s | `TelemetryStale` | Direct — clock since the last decoded `TemperatureUpdate` |
| Selected water temperature or heatsink temperature outside the compile-time envelope, or an implausible single-tick jump | `TemperatureRangeExceeded` / `HeatsinkLimitExceeded` / `ImplausibleTemperatureChange` | Direct — decoded `TemperatureUpdate` fields, `cool_test::evaluate_tick` |
| UART write or read failure | `UartWriteFailure` / `UartReadFailure` | Direct — I/O error from `FrozenLink` |
| Frozen's own link closes | `TelemetryLost` | Direct |
| Selected-side pump still reported off/0V more than `PUMP_CONFIRM_GRACE` after the enable command was accepted | `PumpNotConfirmedRunning` | Direct, evidence-gated: only fires if a decoded firmware `Message` for our side's pump was actually observed reporting zero voltage (`cool_test::parse_pump_report`) — never merely from the absence of a message, since absence is not evidence of failure |
| Firmware `Message` names the selected TEC as locked (matched narrowly: both "tec" and "lock" must appear) | `TecLocked` | Direct — decoded firmware string |
| Frozen sends an unsolicited `TargetUpdate` reporting the selected side disabled after this binary successfully enabled it | `TargetDisabledUnexpectedly` | Direct — decoded protocol acknowledgement |
| Firmware `Message` contains a generic fault keyword (overtemperature, overcurrent, shutdown, fault, failed, locked) after `FAULT_KEYWORD_GRACE` | `FirmwareFaultMessage` | Direct, with a documented carve-out: the literal substring "flash locked" is excluded (see below) |
| Operator types a report of a leak, burning smell, or abnormal noise (or the literal word ABORT) | `OperatorAbort` | Explicit operator input, read from a background stdin watcher started only after all confirmation-phrase reads are complete (`cool_test::spawn_operator_abort_watcher`) |

### The "flash locked" carve-out

`src/frozen/command.rs` documents a captured, real, benign firmware boot-time exchange:

```
Message: FW: flash locked
Message: FW: cal_info valid
```

— paired together, in a context unrelated to any actuator or safety condition (a flash/calibration
status query). The generic fault-keyword scan (`cool_test::is_generic_fault_message`) excludes any
message containing the literal substring "flash locked" specifically so this evidenced, benign
message is never mistaken for a real "...locked" fault; `cool_test::tests::flash_locked_message_does_not_trigger_safe_stop`
proves this does not regress. The narrower TEC-lock check (`is_tec_locked_message`, requiring both
"tec" and "lock") naturally excludes it too, without needing a special case.

### Firmware sensor-unavailable messages: recorded as warnings, not fatal

Real passive telemetry captured from this hardware, with the cover connected and the reservoir
filled, showed the firmware persistently emitting:

```
FW: [capwater] sensor unavailable
FW: [flowrate] sensor unavailable
```

Since the `frozen-passive` test that captured these never operated a pump, flow has not yet been
independently verified as working; these messages are recorded as warnings
(`cool_test::is_known_nonfatal_sensor_message`) and excluded from the generic fault-keyword scan,
rather than treated as an automatic abort condition.

## Direct vs. inferred pump/fan/TEC conclusions

| Component | How this tool can ever mark it PASS | Direct or inferred? |
|---|---|---|
| Frozen command accepted | The enabled `SetTargetTemperature` frame was transmitted and a response (any decoded packet, typically `TargetUpdate`) was received before the active phase ended | **Direct** (decoded protocol acknowledgement) — but this alone is explicitly *never* used to mark pump/fan/TEC as passing (see SAFETY.md/task charter) |
| Pump operation | PASS only if a decoded firmware `Message` for the selected side's pump (`cool_test::parse_pump_report`, e.g. `FW: pump[left] slow @ 6.03V 0.17A`) reports nonzero voltage at least once; FAIL only if the most recent such message reports 0V/off; UNVERIFIED if no pump message for our side was ever decoded | **Direct** (the firmware itself named the pump, side, and a numeric voltage in a decoded string) when present; **UNVERIFIED**, never assumed PASS, if absent |
| Fan operation | Only if a firmware `Message` is received during the active phase whose text contains `"fan"` (case-insensitive) *and* the side tag for the tested side (e.g. `[left]`) | **Direct evidence when present** (the firmware itself named the component and side in a decoded string); **UNVERIFIED, never assumed PASS, if absent** — absence of a message is not proof of failure, so it is not scored FAIL either |
| TEC cooling operation | Only if the tested side's decoded water-temperature samples show a sustained drop (>= 0.10C, last sample vs. first sample) across the active phase | **Inferred** from a telemetry *trend* across multiple samples, per the task's own requirement ("a short test may not appreciably change water temperature... require a defensible trend, not just one sample"); a flat or rising trend is UNVERIFIED (not FAIL), since a short test may simply not show a measurable change |
| Telemetry remained valid | No stale/lost/decode/range/heatsink abort fired, and at least one sample was decoded | **Direct** |
| Emergency shutdown | `safe_stop::SafeStopResult::fully_succeeded()` — I2C reset confirmed and (if a UART link was open) the disable sends confirmed | **Direct** |
| Overall selected-side result | PASS only if command-accepted, telemetry-valid, and emergency-shutdown are all PASS, and no component is an explicit FAIL; otherwise FAIL if anything hard-failed, else INCONCLUSIVE | derived (`cool_test::overall_verdict`) |

Operator observations (pump heard/felt, fan seen/heard, airflow felt, leak observed, unusual
smell/noise, free-text notes) are collected separately and stored in a distinct
`operator_observations` field in the JSON report — never merged into the machine-evidence fields
above, per the task's evidentiary-separation requirement.
