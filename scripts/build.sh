#!/usr/bin/env bash
# Build a Haskell executable as a wasm reactor module and stage it, together
# with its generated JSFFI glue, into worker/generated/.
#
# Run inside `nix develop`, which provides wasm32-wasi-cabal and post-link.mjs.
#
#   scripts/build.sh [target]      # target defaults to demo-wai

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET="${1:-demo-wai}"

if ! command -v wasm32-wasi-cabal >/dev/null; then
  echo "error: wasm32-wasi-cabal not found. Run 'nix develop' first." >&2
  exit 1
fi

echo "==> building exe:$TARGET"
wasm32-wasi-cabal build "exe:$TARGET"

WASM="$(wasm32-wasi-cabal list-bin "exe:$TARGET")"
echo "==> linked $WASM"

mkdir -p worker/generated
cp "$WASM" worker/generated/app.wasm

echo "==> generating JSFFI glue"
"$(wasm32-wasi-ghc --print-libdir)/post-link.mjs" \
  -i worker/generated/app.wasm \
  -o worker/generated/ghc_wasm_jsffi.js

ls -lh worker/generated/app.wasm worker/generated/ghc_wasm_jsffi.js
