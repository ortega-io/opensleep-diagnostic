# opensleep-diagnostic

A staged, **Frozen-only** hardware diagnostic for an Eight Sleep Pod 3 Hub (MT8365/AArch64), built
as a diagnostic-only fork of [OpenSleep](https://github.com/LiamSnow/opensleep) (base version
2.0.0, pinned source commit `29ea3f8f51d208a02b5d2691720157c7ce96c292`).

This is **not** normal OpenSleep. Four of its five subcommands never run the MQTT client, the
profile/temperature scheduler, Sensor management, or LED management, and none installs a service —
every subcommand is a single, bounded, foreground run. The fifth, `frozen-prime-opensleep-init`, is
the one deliberate exception: see SAFETY.md for exactly what that means.

## Subcommands

| Subcommand | Purpose | Actuates hardware? |
|---|---|---|
| `frozen-passive` | Read-only-effect Frozen probe: ping, hardware info, telemetry. Safe with the cover disconnected and no water. | No |
| `frozen-cool-test` | Intentionally activates one cooling channel for a bounded window (default 10s, max 30s). Requires a filled, connected hydraulic loop and multiple explicit confirmations. | Yes — one cooling channel |
| `frozen-prime-test` | Intentionally sends `Prime` exactly once, to fill an empty or partially-filled hydraulic loop, via this binary's own reimplemented reset/transport. Requires a connected cover and multiple explicit confirmations. | Yes — pumps/priming sequence |
| `frozen-prime-opensleep-init` | The same Prime-once operation, but through the real, unmodified upstream OpenSleep initialization and Frozen manager code instead of a reimplemented transport. Requires the same confirmations. Add `--release-frozen-only` for a third, narrower startup mode: releases Frozen from reset with a single-bit I2C read-modify-write instead of the full upstream reset sequence, and drives Frozen through this binary's own audited transport (same as `frozen-prime-test`) rather than the real upstream scheduler. | Yes — pumps/priming sequence |
| `emergency-stop` | Independent fast path: best-effort-disables both sides, then unconditionally asserts the Frozen subsystem reset (I2C `0x20`). Works even if Frozen itself is unresponsive. | Disables only |

Every subcommand accepts `--dry-run`, which performs no I2C or UART writes and instead runs the
same code against a mocked Frozen device — the full flow (including interactive confirmations) is
testable on an ordinary development machine, no hardware required.

## Read this before running anything on real hardware

* **[SAFETY.md](SAFETY.md)** — the operator-facing safety model: what each mode can and cannot do,
  required confirmations, hard limits, abort conditions, and the shared safe-stop sequence.
* **[RUN_ON_POD.md](RUN_ON_POD.md)** — step-by-step instructions for running this on the actual
  Pod 3 Hub, including the download/verification procedure and the water-loop priming/cooling
  sequencing.
* **[PROTOCOL_AUDIT.md](PROTOCOL_AUDIT.md)** — the evidence trail: every command this binary can
  transmit, its exact serialized frame, and which claims are direct protocol evidence versus
  inferred.
* **[TEST_RESULTS.md](TEST_RESULTS.md)** — the automated test suite mapped against the safety
  spec's checklist, and the known gaps stated plainly.

## Building

Reproducible static AArch64 binary via Docker (see `Dockerfile`/`build.sh`):

```sh
./build.sh
```

This clones upstream OpenSleep at the pinned commit, applies `source.patch` (which adds
`src/lib.rs` and `src/bin/opensleep-diagnostic/` and nothing else), runs `cargo test --locked`,
and builds only `--bin opensleep-diagnostic` as a statically linked
`aarch64-unknown-linux-musl` executable. See `build-report.txt` for the most recent build's
toolchain versions, test counts, and artifact checksums.

## Source layout

* `source.patch` — the entire diff against pinned upstream OpenSleep. This is the actual
  deliverable; everything else in this repo (Dockerfile, docs, prebuilt binary) is built from or
  describes it.
* `dist/` — the last built `opensleep-diagnostic-aarch64-static` binary and its `.sha256`.
* `Dockerfile`, `build.sh` — the reproducible build.

## What this binary never does, on any path

No subcommand ever loads the operator's saved `config.ron`, runs the Home Assistant integration, or
transmits `Random`; `Prime` is never transmitted outside `frozen-prime-test`/
`frozen-prime-opensleep-init`. Four of the five subcommands additionally never connect to MQTT,
never open the Sensor subsystem, and never write to the LED controller beyond a nonfatal probe --
`frozen-prime-opensleep-init` is the one deliberate exception, since it runs the real, unmodified
upstream initialization and Frozen manager code (see SAFETY.md for the full writeup on how that
mode's guarantees differ). These are enforced structurally (a closed command type plus a runtime
whitelist for the four audited modes, source-level guardrails for the fifth) and verified by
source-scanning guardrail tests — see SAFETY.md and PROTOCOL_AUDIT.md for the full account.
