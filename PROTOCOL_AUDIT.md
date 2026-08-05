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

| Command | Opcode | Example serialized frame | `frozen-passive` | `frozen-cool-test` | `frozen-prime-test` | `emergency-stop` |
|---|---|---|:---:|:---:|:---:|:---:|
| `Ping` | `0x01` | `7E 01 01 DC BD` | yes | yes | yes | no |
| `GetHardwareInfo` | `0x02` | `7E 01 02 EC DE` | yes | yes | yes | no |
| `GetFirmware` | `0x04` | `7E 01 04 8C 18` | yes (best-effort, after firmware Ping) | yes | yes (best-effort) | no |
| `JumpToFirmware` | `0x10` | `7E 01 10 DE AD` | yes, only if bootloader detected **and** `--allow-firmware-jump` | yes, same gate | yes, same gate | no |
| `GetTemperatures` | `0x41` | `7E 01 41 ...` | yes, 1/s during the telemetry window | yes, ~1/s during baseline + active phases, sent fire-and-forget (see the 0xC1/0x41 finding above) | yes, ~1/s during baseline + active phases, same fire-and-forget pattern | no |
| `SetTargetTemperature(enabled=false)` | `0x40` | see below | yes, both sides | yes, both sides (other side always disabled) | yes, both sides (explicitly disabled before Prime, and by every safe-stop) | yes, both sides (the only thing this subcommand sends) |
| `SetTargetTemperature(enabled=true)` | `0x40` | see below | **never** | yes, **exactly** the one side selected at the CLI | **never** | **never** |
| `Prime` | `0x52` | `7E 01 52 B6 2B` | **never reachable** | **never reachable** | yes, **at most once per run** | **never reachable** |
| `Random(_)` | any | — | **never reachable**: no `FrozenAction::Random` exists | **never reachable** | **never reachable** | **never reachable** |

Disable frame (`enabled=false`, temp field `0x0000`): `7E 05 40 00 00 00 00 <chk_hi> <chk_lo>`.
Enable frame example (`side=Left(0x00)`, `enabled=true`, `temp=3600` i.e. 36.00C):
`7E 05 40 00 01 0E 10 E6 A8` — this exact frame (and its checksum) is asserted byte-for-byte by
upstream's own `frozen::command::tests::test_temp` and `common::checksum::tests::test_checksum`,
reused unmodified by this fork. The `Prime` frame `7E 01 52 B6 2B` is likewise asserted
byte-for-byte by upstream's own `frozen::command::tests::test_prime`, and cross-checked by this
fork's own `prime_test::tests::prime_action_serializes_to_the_exact_source_evidenced_frame`.

### Why `Random` is unreachable, and `Prime` is reachable in exactly one mode

`src/bin/opensleep-diagnostic/safety.rs`'s `FrozenAction` enum has exactly eight variants: `Ping`,
`GetHardwareInfo`, `GetFirmware`, `JumpToFirmware`, `GetTemperatures`, `SafetyOff`, `EnableCooling`,
and `Prime`. There is no `Random` variant, no CLI flag, and no conversion path anywhere in this
binary's source that produces `opensleep::frozen::FrozenCommand::Random(_)` and hands it to the
transport.

`Prime` **is** representable, because `frozen-prime-test` needs to send it, but two independent
mechanisms keep it out of every other mode and bound to at most one send per run:

1. `AuditedTransport::check`'s per-mode whitelist (`safety::allowed_in_mode`) only returns `true`
   for `FrozenAction::Prime` when `self.mode == Mode::PrimeTest`. `Mode::Passive`,
   `Mode::CoolTest`, and `Mode::EmergencyStop` all refuse it -- this is a `match` over every
   `FrozenAction` variant, not a default-permissive check, so a future variant added without an
   explicit arm fails to compile rather than silently passing.
2. `AuditedTransport::check` additionally tracks a per-transport `prime_count`. If `Prime` is
   attempted a second time in the same run (in `Mode::PrimeTest`, where the mode check alone would
   otherwise allow it), `check` refuses it and increments `rejected_command_count` -- this is
   enforced at the transport layer itself, not merely by `frozen-prime-test`'s own control flow
   only calling it once (which is also true, but is not the thing actually relied upon here).

`safety::tests::prime_is_refused_outside_prime_test_mode`,
`prime_test_mode_allows_prime_exactly_once`, `every_frozen_command_variant_is_accounted_for_by_mode`,
and `main.rs`'s `guardrail_tests::frozen_action_prime_is_referenced_only_in_safety_and_prime_test`
(source-level: `FrozenAction::Prime`/`FrozenAction::prime()` never appears outside `safety.rs`/
`prime_test.rs`) together make this an executable, falsifiable claim rather than a design
intention.

As defense in depth, `AuditedTransport::check` *also* checks the serialized opcode byte against a
fixed allowed set (`0x01, 0x02, 0x04, 0x10, 0x40, 0x41, 0x52`) before any frame is transmitted --
so even a hypothetical future bug that somehow produced a `Prime` frame through some other path
would still be refused unless it also passed the mode and at-most-once checks above, which run
first.

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

## `Prime`: full source audit

This section answers, with citations, every question the safety spec asked before implementing
`frozen-prime-test`: whether `Prime` has arguments, whether it applies to one side or both, what
acknowledgment/start/completion evidence exists, whether any cancellation command exists, whether
the normal firmware manager assumes a duration, and what pumps/valves/solenoids are expected to
operate. Every fact below is either a source doc comment, a source code comment containing a
captured real firmware log excerpt, or an existing unit test fixture -- none of it was inferred or
reconstructed from memory.

### The command itself: no arguments, no side, one frame

```rust
// src/frozen/command.rs
pub enum FrozenCommand {
    ...
    #[allow(dead_code)]
    Prime,
    ...
}

impl CommandTrait for FrozenCommand {
    fn to_bytes(&self) -> Vec<u8> {
        match self {
            ...
            Prime => command(vec![0x52]),
            ...
        }
    }
}

// tests:
fn test_prime() {
    assert_eq!(FrozenCommand::Prime.to_bytes(), hex!("7E 01 52 b6 2b").to_vec());
}
```

`Prime` is a unit variant: it takes **no arguments** and, critically, **there is no `side` field or
parameter anywhere in its definition or encoding** -- unlike `SetTargetTemperature { side, tar }`.
The serialized frame is fixed: `7E 01 52 B6 2B` (flag, length 1, opcode `0x52`, then the CRC-CCITT
checksum of `[0x52]`). Since the command carries no side selector, it necessarily **applies to both
sides in a single shot** -- there is no protocol-level way to prime only one side. This is why
`frozen-prime-test` has no `--side` flag (unlike `frozen-cool-test`).

### Direct start acknowledgment: `PrimingStarted` (opcode `0xD2`)

```rust
// src/frozen/packet.rs
pub enum FrozenPacket {
    ...
    PrimingStarted,
    ...
}
match buf[0] {
    ...
    0xD2 => Self::parse_priming_started(buf),
    ...
}
fn parse_priming_started(buf: BytesMut) -> Result<Self, PacketError> {
    validate_packet_size("Frozen/PrimingStarted", &buf, 2)?;
    if buf[1] != 0 {
        log::warn!("PrimingStarted had unexpected value {}", buf[1]);
    }
    Ok(FrozenPacket::PrimingStarted)
}

// src/frozen/state.rs, FrozenState::handle_packet:
FrozenPacket::PrimingStarted => {
    log::info!("Priming started!");
}
```

This is a real, decoded, binary protocol packet (opcode `0xD2`, 2-byte payload) that normal
OpenSleep itself logs as direct evidence priming began. `frozen_prime_test.rs` treats a decoded
`PrimingStarted` -- whether it arrives as the immediate reply to `Prime` or later, unsolicited --
as direct acknowledgment/start evidence (`PrimeResults::prime_acknowledgment` /
`prime_start_observed`).

### Stage messages: `"FW: [priming] ..."`, including the only completion signal

```rust
// src/frozen/state.rs, FrozenState::handle_packet, inside the Message(msg) arm:
} else if let Some(stripped) = msg.strip_prefix("FW: [priming] ") {
    // done because empty
    // done
    // empty stage pause pumps for %u ms
    // empty phase (%u remaining; runtime %u ms)
    // empty stage finished w/ %u successful purge
    // purge phase
    // purge.fast (%u ms)
    // purge_fast stage purged? %u
    // start
    // %u consecutive failed purges; %u total failed
    // purge phase (%u iterations remaining)
    // purge phase complete. now final empty stage
    // purge.wait
    // purge.side (%s: %s)
    // purge.empty, both pumps at 12v
    log::info!("Priming Message: {stripped}");

    match stripped {
        "done" | "done because empty" => self.is_priming = false,
        "start" => self.is_priming = true,
        _ => {}
    }
}
```

This is the complete, real catalog of priming-stage message text upstream's own source documents
(as comments listing observed firmware strings, not executable code -- but a first-hand catalog of
what the firmware actually prints). Key findings from this catalog:

* **`"start"` is a second, independent start signal** (a decoded `Message`, distinct from the
  binary `PrimingStarted` packet) -- `frozen-prime-test` treats either one as sufficient evidence
  of `prime_start_observed`.
* **`"done"` and `"done because empty"` are the *only* completion signals that exist anywhere in
  this protocol.** There is no binary "priming complete" packet analogous to `PrimingStarted`.
  `frozen-prime-test`'s `prime_completion_observed` and the early-stop-on-completion behavior are
  both driven exclusively by these two strings.
* **`"done because empty"` is itself real evidence the firmware detected the reservoir ran dry and
  stopped on its own** -- `frozen-prime-test` records this distinctly
  (`priming_done_because_empty`) and logs a prominent warning when it's seen, since it directly
  confirms a low-reservoir condition even though this is only known *after* the fact, not
  predictively.
* **The purge/empty stage messages mention both pumps ("purge.empty, both pumps at 12v") and
  per-side purge status ("purge.side (%s: %s)"), but never mention a solenoid or a valve by name.**
  See "No solenoid/valve message exists in the reused source" below.
* **`"failed"` appears in this catalog as routine purge-retry accounting** ("%u consecutive failed
  purges; %u total failed"), not as a standalone fatal-error string. `frozen-prime-test` therefore
  never auto-aborts on the mere presence of "failed" (or "locked", "fault", etc.) inside a
  `[priming]`-prefixed message -- see `prime_test::is_generic_fault_message`'s doc comment and the
  "flash locked" carve-out discussion below, which the same reasoning extends to this channel.

### No Prime-cancellation command exists

A full source scan (`grep -rn "solenoid\|valve\|cancel\|abort\|stop.*prim" --include="*.rs"` across
the pinned commit, plus manual reading of `src/frozen/command.rs`'s complete `FrozenCommand` enum
and `manager.rs`) found **no command, in either direction, that cancels or stops an in-progress
Prime.** `FrozenCommand` has exactly the variants listed in the command-whitelist table above; none
of them is a priming-cancel command. This is stated plainly, not glossed over: **subsystem reset
(I2C `0x20`, `reg 0x02 <- 0xFF`) is the only forced-stop mechanism this diagnostic has for an
in-progress Prime**, exactly as SAFETY.md states. `frozen-prime-test` therefore runs the same
shared safe-stop routine (disable-both-sides x3, UART flush, `0x20` reset) on every exit path,
including when `"done"` was already observed, exactly like every other mode.

### Normal OpenSleep does not assume a Prime duration

```rust
// src/config/mod.rs
pub prime: Time,   // a time-of-day, not a duration

// src/frozen/manager.rs, get_next_command:
// TODO verify it actually started priming
if !away_mode
    // prime if we are within 30 seconds of prime time AND we havn't tried to prime in the last minute
    && now.duration_since(timers.last_prime) > Duration::from_secs(60)
    && now_local.duration_until(*prime_time).abs() < SignedDuration::from_secs(30)
{
    timers.last_prime = now;
    return Some(FrozenCommand::Prime);
}
```

Normal OpenSleep's `cfg.prime` is a **scheduled time of day** (e.g. "prime once daily around
6:00am"), not a duration -- and `last_prime` exists purely as a 60-second cooldown to avoid
re-sending `Prime` repeatedly within the same ~30-second window around that scheduled time, not to
track how long priming takes. The `// TODO verify it actually started priming` comment is upstream
itself acknowledging it has no reliable completion tracking either. **No source anywhere assumes or
documents how long a real priming cycle takes to complete.** This is why `frozen-prime-test`'s
duration bounds (5-60s, default 30s) are a deliberately conservative compile-time choice, not a
value derived from a documented firmware timing spec -- stated plainly, matching the same honesty
standard already used for `frozen-cool-test`'s baseline temperature range (see "Baseline/active-
range constants" below).

### What pumps/valves/solenoids are expected to operate

Directly evidenced (source code comments containing captured real firmware log lines,
`frozen/command.rs`):

```
Message: FW: pump[left] slow @ 6.030475V 0.169202A
Message: FW: pump[right] slow @ 6.044009V 0.161510A
```

Both pumps report voltage/current telemetry via decoded `Message` strings during normal operation
(this example is from a heatsink/cooling context, not necessarily during Prime itself, but it is
the only directly-evidenced pump-telemetry format in the pinned source, and `frozen-prime-test`
reuses it, `prime_test::parse_pump_telemetry`). The `[priming]` stage catalog above additionally
confirms **both pumps run together** during the purge/empty stages ("purge.empty, both pumps at
12v") and that priming has **per-side sub-stages** ("purge.side (%s: %s)") even though the top-level
`Prime` command itself is not per-side.

### No solenoid/valve message exists in the reused source

Despite the physical Pod 3 hydraulic loop plausibly containing a solenoid or float valve, **no
source string, comment, or identifier containing "solenoid", "valve", or "float" was found anywhere
in the pinned commit.** `frozen-prime-test`'s solenoid/valve detection
(`prime_test::is_solenoid_or_valve_message`) is therefore a **forward-compatible keyword scan, not
a confirmed protocol feature**: it will record any future firmware message containing those words,
but the complete absence of a match after a real run is not evidence that no solenoid exists or
that priming failed -- it only means this specific firmware revision's `Message` strings never
happened to say so. `PrimeResults::solenoid_operation` reflects this: it is `UNVERIFIED` (never
assumed `PASS`) whenever no such message was seen, exactly like `frozen-cool-test`'s fan-operation
line.

### A related, evidenced signal: reservoir level transitions

```rust
// src/frozen/state.rs, FrozenState::handle_packet:
if msg == "FW: water empty -> full" {
    log::warn!("Water tank reinserted");
} else if msg == "FW: water full -> empty" {
    log::warn!("Water tank removed");
}
```

These are real, evidenced, exact-string firmware messages about a reservoir-level *transition* --
distinct from the `[capwater] sensor unavailable` warning (which is about a *sensor*, not a level
change). `frozen-prime-test` records these (`prime_test::is_reservoir_transition_message`) and
treats `"FW: water empty -> full"` observed during an active run as direct, sufficient evidence of
water circulation for `PrimeResults::water_movement_observed`/`overall_result` -- see "Direct vs.
inferred conclusions for `frozen-prime-test`" below. Since the pinned real captured logs show the
`capwater` sensor reporting unavailable on this hardware revision, these transition messages may
never fire in practice; their absence is not evidence of anything, exactly like the solenoid/valve
scan above.

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

## `frozen-prime-test` active-phase abort conditions and their evidence basis

All are evaluated inside `prime_test::run_core`'s active-phase loop and run the same shared
`safe_stop::run_safe_stop` regardless of which one fired.

| Condition | `StopReason` | Evidence basis |
|---|---|---|
| No fresh, valid unsolicited `TemperatureUpdate` for > 2s | `TelemetryStale` | Direct |
| Either side's water temperature, or the heatsink temperature, outside the compile-time envelope | `TemperatureRangeExceeded` / `HeatsinkLimitExceeded` | Direct — `prime_test::evaluate_temperatures`, checked for both sides every tick since `Prime` affects both at once |
| UART write or read failure, or the link closes | `UartWriteFailure` / `UartReadFailure` / `TelemetryLost` | Direct |
| Firmware `Message` names a pump fault (narrow match: "pump" + a fault word, and not a normal `... @ V A` telemetry line) | `PumpFault` | Direct — `prime_test::is_pump_fault_message` |
| Periodic 0x20 re-probe fails after priming started | `I2cFailureDuringPriming` | Direct — same `probe_address` primitive used at preflight, re-run every 5 ticks |
| Periodic Ping returns `Pong(false)` | `FrozenReturnedToBootloader` | Direct — Frozen itself reporting its own mode |
| Unsolicited `TargetUpdate` reports either side enabled | `TargetEnabledUnexpectedly` | Direct — this mode must never have an enabled target at any point |
| Firmware `Message` contains a generic fault keyword after the fact, outside a cataloged `[priming]`-stage message | `FirmwareFaultMessage` | Direct, with the same "flash locked" carve-out as `frozen-cool-test`, plus the `[priming]`-stage exemption discussed above (real evidence shows "failed" there is routine purge-retry accounting) |
| Firmware reports `"FW: [priming] done"` / `"...done because empty"` before the duration elapses | `PrimingCompleted` | Not an error — a legitimate early-stop, per spec: this mode must never wait out the rest of the window once completion is observed |
| Operator presses Ctrl+C / SIGTERM / SIGHUP | `CtrlC` / `Sigterm` / `Sighup` | Explicit operator/OS signal — the primary operator-stop mechanism for this mode (no typed-ABORT watcher, unlike `frozen-cool-test`; see SAFETY.md for why watching the reservoir and using Ctrl+C is this mode's interlock) |

Two conditions named in the original safety spec are deliberately **not** separately implemented,
stated plainly rather than faked:

* **"The Prime command cannot be serialized"** — `FrozenCommand::to_bytes()` is infallible (it
  always produces bytes; there is no error path), so this is structurally unreachable given the
  reused, unmodified encoder, in the same category as `StopReason::DecodeFailure`/`FatalStatus`
  above.
* **A reliable "reservoir is empty" signal** — no source evidence establishes a voltage/current
  threshold below which the reservoir can be considered empty (see "What pumps/valves/solenoids
  are expected to operate" above: the only directly-evidenced pump values are from a non-priming
  context). Inventing a threshold would be exactly the kind of unevidenced assumption this document
  exists to avoid; the operator watching the reservoir is the real interlock instead.

## Direct vs. inferred pump/fan/TEC conclusions (`frozen-cool-test`)

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

## Direct vs. inferred conclusions (`frozen-prime-test`)

| Component | How this tool can ever mark it PASS | Direct or inferred? |
|---|---|---|
| Frozen application firmware | A valid application-firmware `Pong(true)` was obtained | **Direct** |
| Prime command transmitted | The `Prime` frame was written to the UART without error (passed the audit whitelist and the write succeeded) | **Direct** — never by itself sufficient for `overall_result`, see below |
| Prime acknowledgment | A decoded `PrimingStarted` (0xD2) packet was received as the reply to `Prime` or later | **Direct** when present; **UNVERIFIED**, never FAIL from absence, otherwise |
| Prime start observed | Either a decoded `PrimingStarted` packet or a `"FW: [priming] start"` message was seen | **Direct** when present; **UNVERIFIED** otherwise |
| Left/right pump telemetry | PASS if a decoded pump `Message` for that side ever reports nonzero voltage; FAIL if the most recent one reports 0V/off; UNVERIFIED if no pump message for that side was ever decoded | **Direct** when present; **UNVERIFIED**, never assumed PASS, if absent |
| Left/right pump operator observation | Directly transcribes the operator's yes/no/unsure answer for that side | **Operator evidence**, kept in a separate typed field (`PrimeOperatorObservations`) from every machine-decoded field |
| Solenoid operation | PASS if any decoded `Message` contains "solenoid"/"valve" and none of those messages also suggest a fault; FAIL if one does; UNVERIFIED if none was ever seen | **Direct when present** (forward-compatible scan — no such message has ever been observed in the pinned source, see above); **UNVERIFIED**, never assumed PASS or FAIL, from absence |
| Water movement observed | PASS if a `"FW: water empty -> full"`/`"...full -> empty"` message was seen, **or** the operator answered "yes" to water movement/bubbles observed; FAIL if the operator answered "no" and no direct evidence contradicts it; UNVERIFIED otherwise | **Direct** (firmware message) or **operator evidence** — either one alone is sufficient for this line, but neither is required for the other |
| Prime completion observed | A `"FW: [priming] done"` or `"...done because empty"` message was seen (the only completion signal that exists — see the source audit above) | **Direct** when present; **UNVERIFIED** otherwise |
| Safe-stop and reset | `safe_stop::SafeStopResult::fully_succeeded()` | **Direct** |
| **Overall result** | **PASS only if**: nothing hard-failed (firmware unreachable, Prime never transmitted, safe-stop failed, both pumps FAIL, solenoid FAIL, or an operator-reported leak/burning-smell/abnormal-noise), **and** water circulation is proven either by a direct firmware reservoir-transition message **or** by the operator confirming *both* water movement *and* a dropped reservoir level. Sending Prime, receiving an ack, seeing pump voltage, or seeing "done" printed are each individually **insufficient** for PASS. If nothing failed but circulation isn't proven, the result is **INCONCLUSIVE**, never PASS. | derived (`prime_test::run_core`'s `overall_result` computation) |

This directly implements the safety spec's explicit requirement: *"Do not declare the hydraulic
loop successfully primed solely because: the Prime frame was written / the firmware acknowledged
it / a pump received voltage / 'priming done' was printed."*
`prime_test::tests::overall_result_is_inconclusive_not_pass_from_command_and_pumps_alone` and
`direct_firmware_circulation_evidence_produces_overall_pass` prove both halves of this rule against
mocked devices.

Operator observations for this mode (left/right pump heard/felt, water movement or bubbles
observed, reservoir level dropped, reservoir topped up, leak observed, abnormal noise, burning
smell, free-text notes) use their own distinctly-typed `PrimeOperatorObservations` struct/JSON
field — never merged with `frozen-cool-test`'s `operator_observations` field, and never merged with
any machine-decoded field above.
