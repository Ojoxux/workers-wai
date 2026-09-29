// test-yesod under wrangler dev. Build with scripts/test.sh first.
import wasmModule from "../.test-build/test-yesod/app.wasm";
import jsffi from "../.test-build/test-yesod/ghc_wasm_jsffi.js";
import { makeWorker } from "../worker/src/runtime.mjs";

export default makeWorker(wasmModule, jsffi, { exposeErrors: true });
