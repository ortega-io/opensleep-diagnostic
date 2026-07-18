# syntax=docker/dockerfile:1
#
# Builds `opensleep-diagnostic`, a diagnostic-only, non-actuating fork of a single binary from
# https://github.com/LiamSnow/opensleep, as a statically linked AArch64 musl executable.
#
# This never builds or modifies the normal `opensleep` binary's behavior: it clones upstream at
# a pinned commit, applies source.patch (which only adds src/lib.rs, src/bin/opensleep-diagnostic/,
# and the minimal main.rs/Cargo.toml changes needed to reuse the existing packet codecs, command
# definitions, and serial helpers), and builds only --bin opensleep-diagnostic.

FROM messense/rust-musl-cross:aarch64-musl AS builder

# Pinned to the commit that was current on `main` when this fork was created, so the build is
# reproducible even after upstream `main` moves. Override with --build-arg to build a different
# commit (the source.patch below must still apply cleanly against it).
ARG OPENSLEEP_COMMIT=29ea3f8f51d208a02b5d2691720157c7ce96c292

WORKDIR /work

# The repository requires Rust edition 2024, i.e. rustc >= 1.85. Only attempt `rustup update`
# if the image's preinstalled toolchain doesn't already satisfy that -- the pinned image tag's
# rustup component metadata is out of sync with its (doc-stripped) toolchain directory, which
# makes `rustup update stable` fail while removing the old clippy component. `mkdir -p .../share/doc`
# works around that same bug in case a future/older image tag genuinely needs the update path.
RUN set -eu; \
    rustc --version; cargo --version; \
    ver="$(rustc --version | awk '{print $2}')"; \
    major="$(echo "$ver" | cut -d. -f1)"; minor="$(echo "$ver" | cut -d. -f2)"; \
    if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 85 ]; }; then \
        echo "rustc $ver already satisfies the >=1.85 (edition 2024) requirement; skipping rustup update"; \
    else \
        echo "rustc $ver < 1.85; updating stable toolchain"; \
        mkdir -p "$(rustc --print sysroot)/share/doc"; \
        rustup update stable; \
        rustup default stable; \
    fi; \
    rustc --version; cargo --version

RUN git clone https://github.com/LiamSnow/opensleep.git
WORKDIR /work/opensleep
RUN git checkout "${OPENSLEEP_COMMIT}"

COPY source.patch /tmp/source.patch
RUN git apply --verbose /tmp/source.patch

# The repository's checked-in .cargo/config.toml points the aarch64-unknown-linux-musl target at
# the GNU linker (aarch64-linux-gnu-gcc), which cannot produce a statically linked musl binary.
# Environment variables take precedence over .cargo/config.toml, so this overrides it without
# touching the repo's own config. NOTE: the musl cross-compiler binary in this image is named
# aarch64-unknown-linux-musl-gcc (verified via `find` inside the image), not
# aarch64-linux-musl-gcc -- using the latter (as in some older messense/rust-musl-cross docs)
# fails with "linker not found" against the image tag pinned above.
ENV CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=aarch64-unknown-linux-musl-gcc
ENV RUSTFLAGS="-C target-feature=+crt-static"
# Baked into the diagnostic binary at compile time (via option_env!) and reported in Phase 1's
# startup log line and the JSON/text summary's opensleep_source_commit field.
ENV OPENSLEEP_SOURCE_COMMIT=${OPENSLEEP_COMMIT}

# Runs the whole workspace's test suite (normal opensleep's existing tests, unchanged, plus the
# diagnostic's own safety/mock-transport tests) under the actual release cross-toolchain, via
# this image's built-in QEMU test runner.
RUN cargo test --locked

RUN cargo build \
      --locked \
      --release \
      --target aarch64-unknown-linux-musl \
      --bin opensleep-diagnostic

RUN mkdir -p /output \
 && cp \
      target/aarch64-unknown-linux-musl/release/opensleep-diagnostic \
      /output/opensleep-diagnostic-aarch64-static \
 && cd /output \
 && sha256sum opensleep-diagnostic-aarch64-static \
      > opensleep-diagnostic-aarch64-static.sha256

FROM scratch AS export
COPY --from=builder /output/ /
