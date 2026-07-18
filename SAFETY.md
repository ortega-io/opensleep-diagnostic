# SAFETY.md — opensleep-diagnostic

`opensleep-diagnostic` is a short-running, read-mostly hardware probe for an Eight Sleep Pod 3
Hub. It is **not** a fork of the normal `opensleep` runtime and does **not** run any of its
control loops, timers, or schedulers. This document is the authoritative list of every command
this binary can transmit, and the mechanisms that make every other command unreachable.

The Hub this tool targets is not connected to a mattress cover and is not filled with water. It
is not safe for pump, TEC, heating, cooling, vibration, alarm, or priming operations. This tool
was built specifically so those operations are structurally impossible to trigger from it.

## The complete list of commands this binary can ever transmit

### Frozen subsystem (`/dev/ttyS1` by default, 38400 baud, 8N1, no flow control)

| Command | Opcode | Serialized frame | Sent when |
|---|---|---|---|
| `Ping` | `0x01` | `7E 01 01 DC BD` | Always, first Frozen command |
| `GetHardwareInfo` | `0x02` | `7E 01 02 EC DE` | After a successful Ping |
| `GetFirmware` | `0x04` | `7E 01 04 8C 18` | After a successful Ping (best-effort, passive) |
| `JumpToFirmware` | `0x10` | `7E 01 10 DE AD` | Only if Frozen is detected in its bootloader **and** `--allow-firmware-jump` was passed |

### Sensor subsystem (`/dev/ttyS2` by default, 115200 baud firmware / 38400 baud bootloader, 8N1, no flow control)

| Command | Opcode | Serialized frame | Sent when |
|---|---|---|---|
| `Ping` | `0x01` | `7E 01 01 DC BD` | At firmware baud first, then at bootloader baud if unanswered; again after a firmware jump |
| `GetHardwareInfo` | `0x02` | `7E 01 02 EC DE` | After a successful firmware-mode Ping (initial or post-jump) |
| `GetFirmwareHash` | `0x04` | `7E 01 04 8C 18` | After a successful firmware-mode Ping (best-effort, passive) |
| `JumpToFirmware` | `0x10` | `7E 01 10 DE AD` | Only if Sensor is detected in its bootloader **and** `--allow-firmware-jump` was passed |

(Frame bytes are from `opensleep`'s own encoder — `FrozenCommand`/`SensorCommand::to_bytes()` —
and are exercised directly by this fork's unit tests, e.g. `frozen::command::tests::test_ping`
and `sensor::command::tests::test_sensor_commands`, which the diagnostic reuses unmodified.)

### I2C bus (`/dev/i2c-1` by default)

* Read-only one-byte probe of `0x20` (reset/enable expander) — never a write, unless
  `--reset-subsystems` is passed.
* Read-only one-byte probe of `0x53` (LED controller) — always read-only, never skipped from
  being read-only even when the probe itself is skipped via `--skip-led-probe`.
* Only with `--reset-subsystems`: exactly four writes to `0x20`, in this fixed order, mirroring
  `opensleep::reset::ResetController::reset_subsystems`'s existing sequence:
  1. `reg 0x06 <- 0xFC`
  2. `reg 0x07 <- 0x31`
  3. `reg 0x02 <- 0xFF`
  4. `reg 0x02 <- 0xFD`

  No other register, on `0x20` or any other address, is ever written by this binary.

## What is never reachable, and why

Every command listed below exists in the shared `opensleep` library crate (this fork reuses that
crate's packet codecs and command definitions rather than reimplementing them), but none of them
can be constructed or transmitted from `opensleep-diagnostic`:

**Frozen:** `SetTargetTemperature` (`0x40`), `GetTemperatures` (`0x41`), `Prime` (`0x52`),
`Random(_)`.

**Sensor:** `SetPiezoFreq` (`0x21`), `GetPiezoFreq` (`0x20`), `EnablePiezo` (`0x28`),
`DisablePiezo` (`0x29`), `SetPiezoGain` (`0x2B`), `EnableVibration` (`0x2E`),
`ProbeTemperature` (`0x2F`), `SetAlarm` (`0x2C`), `ClearAlarm` (`0x2D`), `GetHeaterOffset`
(`0x2A`), `Random(_)`.

**I2C `0x53` (LED controller):** any write at all — reset, mode, brightness, pattern, or color
registers.

This is enforced structurally, on two independent layers, not by convention or careful coding
alone:

1. **Closed probe enums.** `FrozenProbe` and `SensorProbe` (`src/bin/opensleep-diagnostic/safety.rs`)
   are the *only* types this binary ever converts into a `FrozenCommand`/`SensorCommand`. Each has
   exactly four variants — `Ping`, `GetHardwareInfo`, `GetFirmware(Hash)`, `JumpToFirmware` — and
   there is no CLI flag, constructor, or code path anywhere in this binary that produces any other
   variant of the underlying library command enums. `GetTemperatures` is deliberately excluded
   from the Frozen whitelist even though it looks observational, per this tool's own charter.
2. **`SafetyAudit`, a runtime whitelist gate.** Every single outgoing frame — on the real serial
   port and in every test — passes through `SafetyAudit::check`, which encodes the command,
   reads the opcode byte, and refuses to record/allow it unless that opcode is in a fixed
   per-subsystem whitelist (`FROZEN_WHITELIST` / `SENSOR_WHITELIST`, both `[0x01, 0x02, 0x04,
   0x10]`). This is defense in depth: even if a future change accidentally reached a disallowed
   command through some other path, `SafetyAudit` still refuses to send it.
   `safety::tests::frozen_actuator_commands_are_rejected` and
   `safety::tests::sensor_actuator_and_config_commands_are_rejected` construct every disallowed
   command directly (bypassing the closed enums, using the shared library's own types) and assert
   `SafetyAudit` rejects every one of them.

`JumpToFirmware` is on the whitelist opcode-wise (it is not an actuator command — it only
transitions an MCU from its bootloader to its normal firmware) but is additionally gated behind
the `--allow-firmware-jump` CLI flag at the call site in `frozen_phase.rs`/`sensor_phase.rs`, and
is never followed by any temperature, pump, or priming command in either phase.
`frozen_phase::tests::jump_to_firmware_is_never_sent_without_opt_in` and
`sensor_phase::tests::jump_to_firmware_not_sent_without_opt_in_even_in_bootloader` assert this
holds even when the target hardware is actively detected as being in its bootloader.

## Other guarantees

* `--skip-led-probe` only skips the *read* of `0x53`; there is no flag, in this tool, that could
  make it write to `0x53` instead.
* This binary never loads `config.ron`, never connects to MQTT, never runs Home Assistant
  integration, never starts a profile or temperature schedule, and never installs or touches a
  systemd unit. None of the code paths that do those things (`opensleep::config::Config::load`,
  `opensleep::mqtt`, `opensleep::frozen::manager::run`, `opensleep::sensor::manager::run`) are
  called anywhere in `src/bin/opensleep-diagnostic/`.
* The "Actuator commands sent" line in every summary (text and JSON) is hardcoded to `0`, not
  computed from runtime state — because, given the two layers above, it is structurally
  impossible for it to be anything else.
* This tool always exits after a single diagnostic pass (see `report::compute_exit_code` for the
  exit-code mapping). It is not a daemon and does not loop.
