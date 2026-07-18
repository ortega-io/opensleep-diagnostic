#!/usr/bin/env bash
# Builds opensleep-diagnostic as a statically linked AArch64 musl binary using the
# messense/rust-musl-cross:aarch64-musl cross-compiler image, and validates the result.
#
# Run on an ordinary x86-64 Docker host: this is a cross-compiler image, so no --platform flag
# or emulated-ARM64 host is required.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> Building opensleep-diagnostic (aarch64-unknown-linux-musl, static)"
docker buildx build \
    --output type=local,dest=dist \
    "$@" \
    .

echo
echo "==> Build artifacts:"
ls -la dist/

BIN="dist/opensleep-diagnostic-aarch64-static"

if [ ! -f "$BIN" ]; then
    echo "ERROR: expected artifact $BIN not found" >&2
    exit 1
fi

echo
echo "==> file(1):"
file "$BIN"

echo
echo "==> readelf -l (checking for absence of a dynamic interpreter):"
if command -v readelf >/dev/null 2>&1; then
    readelf -l "$BIN"
else
    echo "readelf not available on this host; skipping (verify inside a container if needed)"
fi

echo
echo "==> sha256sum:"
sha256sum "$BIN"

echo
echo "==> Verifying checksum file matches:"
(cd dist && sha256sum -c "$(basename "$BIN").sha256")

echo
echo "Done. See dist/opensleep-diagnostic-aarch64-static and its .sha256 file."
