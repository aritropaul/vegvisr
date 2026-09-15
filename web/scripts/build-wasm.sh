#!/usr/bin/env bash
# wasm-pack was archived in 2025; drive cargo + wasm-bindgen-cli directly.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=src/wasm
mkdir -p "$OUT"

echo "==> cargo build (wasm32, simd128)"
(cd crates/worldgen && cargo build --release --target wasm32-unknown-unknown)

echo "==> wasm-bindgen"
wasm-bindgen --target web \
  crates/worldgen/target/wasm32-unknown-unknown/release/worldgen.wasm \
  --out-dir "$OUT" --out-name worldgen

if command -v wasm-opt >/dev/null 2>&1; then
  echo "==> wasm-opt -O3"
  wasm-opt -O3 --enable-simd "$OUT/worldgen_bg.wasm" -o "$OUT/worldgen_bg.wasm"
else
  echo "==> wasm-opt not found, skipping (install binaryen for a smaller build)"
fi

ls -lh "$OUT"
