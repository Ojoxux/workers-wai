// Cloudflare Workers entry point. Build with scripts/build.sh first.
import wasmModule from "../generated/app.wasm";
import jsffi from "../generated/ghc_wasm_jsffi.js";
import { makeWorker } from "./runtime.mjs";

export default makeWorker(wasmModule, jsffi);
