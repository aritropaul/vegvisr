#!/usr/bin/env bash
# Build and run both parity harnesses, then gate the difference.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${TMPDIR:-/tmp}/vegvisr-parity"
mkdir -p "$OUT"

echo "==> rust harness"
(cd web/crates/worldgen && cargo run --release --quiet --example parity) > "$OUT/rust.txt"

echo "==> swift harness"
(cd apple && swift run -c release parity) > "$OUT/swift.txt"

echo "==> gate"
exec python3 scripts/parity.py "$OUT/rust.txt" "$OUT/swift.txt"
