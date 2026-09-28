#!/usr/bin/env bash
# Build a Haskell executable as a wasm reactor module and stage it, together
# with its generated JSFFI glue, into worker/generated/.
#
# Run inside `nix develop`, which provides wasm32-wasi-cabal and post-link.mjs.
#
#   scripts/build.sh [target] [out-dir]   # defaults: demo-wai, worker/generated

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="${1:-demo-wai}"
OUT="${2:-worker/generated}"

if ! command -v wasm32-wasi-cabal >/dev/null; then
  echo "error: wasm32-wasi-cabal not found. Run 'nix develop' first." >&2
  exit 1
fi

echo "==> building exe:$TARGET"
wasm32-wasi-cabal build "exe:$TARGET"

WASM="$(wasm32-wasi-cabal list-bin "exe:$TARGET")"
echo "==> linked $WASM"

mkdir -p "$OUT"
cp "$WASM" "$OUT/app.wasm"

echo "==> generating JSFFI glue"
"$(wasm32-wasi-ghc --print-libdir)/post-link.mjs" \
  -i "$OUT/app.wasm" \
  -o "$OUT/ghc_wasm_jsffi.js"

ls -lh "$OUT/app.wasm" "$OUT/ghc_wasm_jsffi.js"
