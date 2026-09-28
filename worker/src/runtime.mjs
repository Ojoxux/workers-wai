// The JavaScript half of cloudflare-workers.
//
//   import { makeWorker } from "./runtime.mjs";
//   export default makeWorker(wasmModule, jsffi);
//
// Boots the Haskell wasm reactor module once per isolate and forwards every
// fetch event to the `handleRequest` export defined by Cloudflare.Workers.Entry.
//
// Boot order, on the first request:
//   1. string-valued env entries become the WASI environ (unless envAsEnviron
//      is false), so System.Environment.lookupEnv sees Secrets and vars
//   2. instantiate, tying the JSFFI knot
//   3. _initialize: wasm constructors and the Haskell RTS
//   4. setEnv(env): hands the env object to Haskell
//   5. workerMain(): the application's main, which calls runWorker
//
// Instantiation happens on the first request rather than at module scope, so
// it is billed as request time instead of against the startup CPU limit.

import { createWasi } from "./wasi.mjs";

export function makeWorker(wasmModule, jsffi, { envAsEnviron = true } = {}) {
  let booted = null;

  async function boot(env) {
    const environ = envAsEnviron
      ? Object.fromEntries(
          Object.entries(env).filter(([, value]) => typeof value === "string"),
        )
      : {};
    const wasi = createWasi({ env: environ });

    // The JSFFI imports need the instance's exports, which do not exist until
    // instantiation finishes: pass a table that is filled in afterwards.
    const exports = {};
    const instance = await WebAssembly.instantiate(wasmModule, {
      wasi_snapshot_preview1: wasi.imports,
      ghc_wasm_jsffi: jsffi(exports),
    });
    Object.assign(exports, instance.exports);
    wasi.initialize(instance);

    await instance.exports.setEnv(env);
    await instance.exports.workerMain();
    return instance;
  }

  return {
    async fetch(request, env = {}, ctx) {
      if (booted === null) booted = boot(env);

      const pending = booted;
      let instance;
      try {
        instance = await pending;
      } catch (err) {
        // Let the next request retry rather than wedging the isolate, unless a
        // later request has already started a new boot.
        if (booted === pending) booted = null;
        return new Response(`wasm boot failed: ${err?.stack ?? err}\n`, {
          status: 500,
          headers: { "content-type": "text/plain; charset=utf-8" },
        });
      }

      return instance.exports.handleRequest(request, ctx);
    },
  };
}
