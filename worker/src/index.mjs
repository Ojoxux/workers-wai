// Cloudflare Workers entry point.
//
// Boots the Haskell wasm reactor module once per isolate, then forwards every
// fetch event to the `handleRequest` export that
// Network.Wai.Handler.Cloudflare defines.

import wasmModule from "../generated/app.wasm";
import ghcWasmJsffi from "../generated/ghc_wasm_jsffi.js";
import { createWasi } from "./wasi.mjs";

// Instantiation happens on the first request rather than at module scope, so
// it is billed as request time instead of counting against the much tighter
// startup CPU time limit. The promise is cached, so concurrent first requests
// share one boot.
let booted = null;

async function boot() {
  const wasi = createWasi();

  // The ghc_wasm_jsffi imports need to reach the instance's exports, which do
  // not exist until instantiation finishes. GHC's documented workaround is to
  // hand the import object a table that gets filled in afterwards.
  const exports = {};

  const instance = await WebAssembly.instantiate(wasmModule, {
    wasi_snapshot_preview1: wasi.imports,
    ghc_wasm_jsffi: ghcWasmJsffi(exports),
  });

  Object.assign(exports, instance.exports);
  wasi.initialize(instance);

  // Reactor modules have no entry point of their own: run `main` once so the
  // application registers itself via runCloudflare.
  await instance.exports.waiMain();

  return instance;
}

export default {
  async fetch(request) {
    if (booted === null) booted = boot();

    let instance;
    try {
      instance = await booted;
    } catch (err) {
      // Let the next request retry rather than wedging the isolate.
      booted = null;
      return new Response(`wasm boot failed: ${err?.stack ?? err}\n`, {
        status: 500,
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }

    return instance.exports.handleRequest(request);
  },
};
