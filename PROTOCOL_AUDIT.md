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

## Commands permitted per mode

| Command | Opcode | Example serialized frame | `frozen-passive` | `frozen-cool-test` | `emergency-stop` |
|---|---|---|:---:|:---:|:---:|
| `Ping` | `0x01` | `7E 01 01 DC BD` | yes | yes | no |
| `GetHardwareInfo` | `0x02` | `7E 01 02 EC DE` | yes | yes | no |
| `GetFirmware` | `0x04` | `7E 01 04 8C 18` | yes (best-effort, after firmware Ping) | yes | no |
| `JumpToFirmware` | `0x10` | `7E 01 10 DE AD` | yes, only if bootloader detected **and** `--allow-firmware-jump` | yes, same gate | no |
| `GetTemperatures` | `0x41` | `7E 01 41 ...` | yes, 1/s during the telemetry window | yes, during baseline + active phases | no |
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
| `left_temp` | `GetTemperature` (solicited, opcode `0xC1`) / `TemperatureUpdate` (unsolicited, opcode `0x41`) | centidegrees Celsius | left-side water temperature | baseline validation, active-phase range/trend checks, CSV `left_water_c` |
| `right_temp` | same | centidegrees Celsius | right-side water temperature | same, other side |
| `heatsink_temp` | same | centidegrees Celsius | heatsink temperature | active-phase ceiling check, CSV `heatsink_c` |
| `unknown_temp` | `GetTemperature` only | centidegrees Celsius (source: "unknown_temp ... centidegrees celcius") | undocumented 4th channel | reported raw+converted, not used for any safety decision (its meaning is not established) |
| `error` | `TemperatureUpdate` only | source doc comment: "error in deg celcius" | **not** a fault/status flag by this evidence — see below | reported for display only; never gates pass/fail |
| `count` | `TemperatureUpdate` only | wrapping counter | sequence counter | reported only |

### Temperature-unit evidence

`src/frozen/packet.rs` documents `FrozenTarget::temp`, `TemperatureUpdate`'s three temperature
fields, and `GetTemperature`'s four temperature fields as `centidegrees celcius` in source doc
comments (unmodified). `src/frozen/command.rs`'s own `test_temp` unit test constructs
`FrozenTarget { enabled: true, temp: 3600 }` and asserts the serialized bytes are `0E 10` (3600
decimal), consistent with 36.00C as a plausible heating-pad setpoint. Both facts agree, so this
tool divides every raw `u16` by 100 to get degrees Celsius
(`telemetry::centideg_to_celsius`), and documents this rather than assuming it.

### `TemperatureUpdate.error`: why it is not treated as a fault code

`src/frozen/command.rs` contains a captured real firmware log excerpt (a source code comment, not
executable): `Temperature update - Left: 2581, Right: 2581, Heatsink: 2362, Error: 8` appearing
immediately alongside `Message: FW: pid[heatsink] 3.062500 0.693750 0.693750 0.000000 0.000000` —
i.e. the "Error: 8" line is logged next to PID-loop debug output, not next to any fault/alarm
text. Combined with the struct field's own doc comment ("error in deg celcius"), the most
defensible reading is that this is a **PID error term** (a normal, usually-nonzero control-loop
value), not a boolean/enum fault flag. Treating any nonzero value as unsafe would make the
diagnostic reject essentially every real reading; this tool instead reports the raw value for the
operator to read, and does not gate any pass/fail decision on it.

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

None of these constants are derived from an upstream-documented safe range (none exists in the
pinned source); SAFETY.md states this plainly rather than presenting them as spec-derived.

## Direct vs. inferred pump/fan/TEC conclusions

| Component | How this tool can ever mark it PASS | Direct or inferred? |
|---|---|---|
| Frozen command accepted | The enabled `SetTargetTemperature` frame was transmitted and a response (any decoded packet, typically `TargetUpdate`) was received before the active phase ended | **Direct** (decoded protocol acknowledgement) — but this alone is explicitly *never* used to mark pump/fan/TEC as passing (see SAFETY.md/task charter) |
| Pump / Fan operation | Only if a firmware `Message` (opcode `0x07`, decoded as `FrozenPacket::Message(String)`) is received during the active phase whose text contains `"pump"`/`"fan"` (case-insensitive) *and* the side tag for the tested side (e.g. `[left]`) | **Direct evidence when present** (the firmware itself named the component and side in a decoded string); **UNVERIFIED, never assumed PASS, if absent** — absence of a message is not proof of failure, so it is not scored FAIL either |
| TEC cooling operation | Only if the tested side's decoded water-temperature samples show a sustained drop (>= 0.10C, last sample vs. first sample) across the active phase | **Inferred** from a telemetry *trend* across multiple samples, per the task's own requirement ("a short test may not appreciably change water temperature... require a defensible trend, not just one sample"); a flat or rising trend is UNVERIFIED (not FAIL), since a short test may simply not show a measurable change |
| Telemetry remained valid | No stale/lost/decode/range/heatsink abort fired, and at least one sample was decoded | **Direct** |
| Emergency shutdown | `safe_stop::SafeStopResult::fully_succeeded()` — I2C reset confirmed and (if a UART link was open) the disable sends confirmed | **Direct** |
| Overall selected-side result | PASS only if command-accepted, telemetry-valid, and emergency-shutdown are all PASS, and no component is an explicit FAIL; otherwise FAIL if anything hard-failed, else INCONCLUSIVE | derived (`cool_test::overall_verdict`) |

Operator observations (pump heard/felt, fan seen/heard, airflow felt, leak observed, unusual
smell/noise, free-text notes) are collected separately and stored in a distinct
`operator_observations` field in the JSON report — never merged into the machine-evidence fields
above, per the task's evidentiary-separation requirement.
