// test-worker under wrangler dev. Build with: scripts/test.sh (or
// scripts/build.sh test-worker .test-build/test-worker).
import wasmModule from "../.test-build/test-worker/app.wasm";
import jsffi from "../.test-build/test-worker/ghc_wasm_jsffi.js";
import { makeWorker } from "../worker/src/runtime.mjs";

export default makeWorker(wasmModule, jsffi);
