# SAFETY.md — opensleep-diagnostic

`opensleep-diagnostic` is a staged, **Frozen-only** hardware diagnostic for an Eight Sleep Pod 3
Hub. It is not a fork of normal `opensleep` and does not run its control loops, timers, MQTT
client, profile scheduler, or Sensor/LED management. It never installs a systemd service and never
runs unattended — every invocation is a single foreground command that starts, does its work, and
exits.

**Read this whole document before running `frozen-cool-test` on real hardware.**

## The two safety tiers

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

## Hazards specific to this hardware

* The Hub's case may contain energized areas once the cover is connected and a cooling channel is
  active (pump driver, TEC driver, heatsink). **Do not touch or meter the open board while an
  active test is running.**
* Keep a way to physically disconnect Hub power available at all times during an active test —
  don't rely on software alone.
* **Never run `Prime` from this diagnostic.** It is not implemented anywhere in this binary: there
  is no `FrozenAction::Prime` (or `Random`) variant, so it cannot be constructed, whitelisted, or
  transmitted, in any mode, under any flag combination. See PROTOCOL_AUDIT.md for the structural
  proof.
* Test **only one side per invocation**. `frozen-cool-test --side left` can never also enable
  `right` in the same run — see "Command whitelist" below.
* **Stop immediately** (Ctrl+C, or run `opensleep-diagnostic emergency-stop` from a second
  session) if you observe a leak, a burning smell, abnormal noise, or anything that feels
  excessively hot.

## Command whitelist — the complete list of commands this binary can ever transmit

Every outgoing Frozen command passes through `safety::AuditedTransport::check`, which enforces a
fixed per-mode whitelist (see `src/bin/opensleep-diagnostic/safety.rs`). The full command,
opcode, and evidence table is in `PROTOCOL_AUDIT.md`; in summary:

| Mode | Permitted commands |
|---|---|
| `frozen-passive` | `Ping`, `GetHardwareInfo`, `GetFirmware`, `JumpToFirmware`, `GetTemperatures`, `SetTargetTemperature(enabled=false)` for either side |
| `frozen-cool-test` | everything `frozen-passive` permits, **plus** `SetTargetTemperature(enabled=true)` for exactly the one side selected at the CLI (fixed for the whole run; the other side can only ever be sent `enabled=false`) |
| `emergency-stop` | `SetTargetTemperature(enabled=false)` for LEFT and RIGHT, and the `0x20` reset-assert write only |

**Never reachable, in any mode:** `Prime` (`0x52`), `Random(_)`, any raw/undocumented opcode, an
absolute (non-derived) temperature target, or a simultaneously-enabled left+right target. This is
enforced structurally in two independent layers (a closed `FrozenAction` enum with no
`Prime`/`Random` variant, plus the runtime whitelist gate), not by convention — see
`safety::tests` and PROTOCOL_AUDIT.md.

## Active-test limits (hard-coded; no CLI flag can override them)

* Exactly one side per invocation; cooling only (no heating) in this first build.
* Default cooling delta: 1.0C below the measured baseline. **Maximum permitted delta: 2.0C** —
  `safety::FrozenAction::enable_cooling` refuses to construct a command for a larger delta.
* Default active duration: 15 seconds. **Absolute maximum: 30 seconds** —
  `cool_test::run` refuses to start at all if `--duration-seconds` exceeds this.
* The baseline water temperature must fall within **15.00C–35.00C**
  (`cool_test::MIN_WATER_CENTIDEG`/`MAX_WATER_CENTIDEG`) before the test proceeds. This range is a
  conservative, compile-time choice (not derived from a documented firmware spec — see
  PROTOCOL_AUDIT.md for why no tighter, evidence-backed range could be established) intended to
  reject a disconnected/faulted sensor (implausible highs/lows, `0`/`0xFFFF` sentinels) while still
  accepting any plausible indoor ambient-to-body-adjacent water temperature.
* No `Prime`. No arbitrary/absolute commands.

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

## Safe-stop

One shared routine (`safe_stop::run_safe_stop`) runs before every active test, on normal
completion, on Ctrl+C/SIGTERM/SIGHUP, on timeout, on any communication or telemetry error, and
(via a `catch_unwind` boundary around the per-tick evaluation logic) after an internal panic in
that logic. It always: sends `SetTargetTemperature(enabled=false)` for LEFT and RIGHT three times
with short delays, flushes the UART, and asserts `0x20` subsystem reset (`reg 0x02 <- 0xFF`),
leaving the subsystem in that asserted-reset state. A run is only reported PASS if this completes
successfully. If the UART disable fails but the I2C reset succeeds, the run is reported
**degraded**, not PASS. If the I2C reset *also* fails, the program prints an explicit instruction
to disconnect Hub power immediately.

## Keep a second session open

Before starting `frozen-cool-test`, open a second SSH session to the Hub with this ready to run:

```sh
opensleep-diagnostic emergency-stop
```

`emergency-stop` requires no config, MQTT, Sensor, or LED access, and works even if Frozen itself
is unresponsive (it best-effort-disables both sides, then unconditionally asserts the I2C reset,
which is the real backstop). It exits non-zero if the reset could not be confirmed.

## What this binary never does, on any path

* Never loads `config.ron`, never connects to MQTT, never runs the Home Assistant integration.
* Never calls `opensleep::frozen::manager::run` (the normal command-scheduling loop) or any
  profile/priming logic.
* Never opens the Sensor subsystem UART or references `opensleep::sensor` at all.
* Never writes to the `0x53` LED controller — only ever a read-only, nonfatal probe.
* Never installs or touches a systemd unit; every run is a single foreground pass.

These are enforced both by the fact that this binary's source never references those code paths
(`main_guardrail_tests` in `main.rs` scans the diagnostic's own sources at test time to prove it)
and by the command whitelist above.
