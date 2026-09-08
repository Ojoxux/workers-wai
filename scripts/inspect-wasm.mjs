// Dump the imports and exports of a wasm module.
//
// The WASI shim in worker/src/wasi.mjs implements exactly the
// wasi_snapshot_preview1 functions listed here -- run this after changing
// the GHC version or the dependency set to see whether the required set
// has grown.
//
//   node scripts/inspect-wasm.mjs worker/generated/app.wasm

import { readFileSync } from "node:fs";

const path = process.argv[2];
if (!path) {
  console.error("usage: node scripts/inspect-wasm.mjs <file.wasm>");
  process.exit(1);
}

const bytes = readFileSync(path);
const mod = await WebAssembly.compile(bytes);

const byModule = new Map();
for (const imp of WebAssembly.Module.imports(mod)) {
  if (!byModule.has(imp.module)) byModule.set(imp.module, []);
  byModule.get(imp.module).push(`${imp.name} (${imp.kind})`);
}

console.log(`# ${path} (${(bytes.length / 1024 / 1024).toFixed(2)} MiB)`);

for (const [name, entries] of byModule) {
  console.log(`\n## imports from "${name}" (${entries.length})`);
  for (const e of entries.sort()) console.log(`  ${e}`);
}

const exports_ = WebAssembly.Module.exports(mod);
console.log(`\n## exports (${exports_.length})`);
for (const e of exports_) console.log(`  ${e.name} (${e.kind})`);
