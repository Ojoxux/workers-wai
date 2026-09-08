// Boot the wasm module under Node using the same WASI shim as the Worker and
// drive it with synthetic Requests.
//
// This exercises the whole Request -> WAI -> Response path in about a second,
// without starting wrangler. Node exposes the same Request/Response/URL globals
// that the Workers runtime does, so the handler code under test is identical.
//
//   node scripts/smoke.mjs

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const generated = join(root, "worker", "generated");

const { createWasi } = await import(join(root, "worker", "src", "wasi.mjs"));
const ghcWasmJsffi = (await import(join(generated, "ghc_wasm_jsffi.js"))).default;

const wasmModule = await WebAssembly.compile(readFileSync(join(generated, "app.wasm")));

const wasi = createWasi();
const exports = {};
const instance = await WebAssembly.instantiate(wasmModule, {
  wasi_snapshot_preview1: wasi.imports,
  ghc_wasm_jsffi: ghcWasmJsffi(exports),
});
Object.assign(exports, instance.exports);
wasi.initialize(instance);
await instance.exports.waiMain();

const cases = [
  { name: "root", request: new Request("http://localhost:8787/") },
  {
    name: "path + query + headers",
    request: new Request("http://localhost:8787/a/b?x=1&y=2", {
      headers: { "X-Demo": "yes", "CF-Connecting-IP": "203.0.113.7" },
    }),
  },
  {
    name: "HEAD",
    request: new Request("http://localhost:8787/", { method: "HEAD" }),
  },
  {
    name: "POST with body",
    request: new Request("http://localhost:8787/echo", {
      method: "POST",
      headers: { "Content-Type": "text/plain" },
      body: "hello body",
    }),
  },
  {
    name: "responseStream",
    request: new Request("http://localhost:8787/stream"),
  },
];

let failures = 0;

for (const { name, request } of cases) {
  try {
    const response = await instance.exports.handleRequest(request);
    const body = await response.text();
    console.log(`\n--- ${name} ---`);
    console.log(`${response.status}`);
    for (const [k, v] of response.headers) console.log(`  ${k}: ${v}`);
    console.log(JSON.stringify(body));
    if (response.status >= 500) failures++;
  } catch (err) {
    failures++;
    console.error(`\n--- ${name} --- FAILED\n${err?.stack ?? err}`);
  }
}

console.log(failures === 0 ? "\nall cases ok" : `\n${failures} case(s) failed`);
process.exit(failures === 0 ? 0 : 1);
