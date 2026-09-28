#!/usr/bin/env bash
# Build every wasm target the integration tests load, into .test-build/<target>,
# then run test/*.test.mjs with Node's built-in test runner.
#
#   scripts/test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGETS=(test-worker demo-wai demo-yesod)

for target in "${TARGETS[@]}"; do
  scripts/build.sh "$target" ".test-build/$target"
done

# --test-force-exit: Yesod starts a background Haskell thread (auto-update /
# date cache) whose threadDelay the wasm RTS implements with setTimeout, which
# would otherwise keep the Node process alive forever. Harmless on Workers,
# where timers die with the request.
node --test --test-force-exit "test/*.test.mjs"
