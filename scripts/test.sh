#!/usr/bin/env bash
# Build every wasm target the integration tests load, into .test-build/<target>,
# then run test/*.test.mjs with Node's built-in test runner.
#
#   scripts/test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGETS=(test-worker test-yesod test-vendor demo-wai demo-yesod)

for target in "${TARGETS[@]}"; do
  scripts/build.sh "$target" ".test-build/$target"
done

# --test-force-exit: Yesod starts a background Haskell thread (auto-update /
# date cache) whose threadDelay the wasm RTS implements with setTimeout, which
# would otherwise keep the Node process alive forever. Whether workerd treats
# these timers the same way once a request ends is checked separately against
# wrangler dev, not here.
# --test-timeout: a test that never settles fails instead of hanging the run.
node --test --test-force-exit --test-timeout=30000 "test/*.test.mjs"
