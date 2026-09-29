#!/usr/bin/env bash
# Build every wasm target the integration tests load, into .test-build/<target>,
# then run test/*.test.mjs with Node's built-in test runner.
#
#   scripts/test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGETS=(test-worker)

for target in "${TARGETS[@]}"; do
  scripts/build.sh "$target" ".test-build/$target"
done

node --test "test/*.test.mjs"
