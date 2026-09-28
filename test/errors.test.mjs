import { test } from "node:test";
import assert from "node:assert/strict";
import { makeWorker } from "../worker/src/runtime.mjs";
import { BASE, fakeCtx, loadWasm, loadWorker } from "./harness.mjs";

test("a throwing Response constructor becomes a 500, not a crash", async () => {
  const worker = await loadWorker("test-worker");
  const { ctx } = fakeCtx();
  const res = await worker.fetch(new Request(`${BASE}/status/99`), {}, ctx);
  assert.equal(res.status, 500);
  assert.match(await res.text(), /RangeError/);

  // The isolate still serves requests afterwards.
  const again = await worker.fetch(new Request(`${BASE}/hello`), {}, fakeCtx().ctx);
  assert.equal(await again.text(), "hello");
});

test("a failed boot is retried on the next request", async () => {
  const { wasmModule, jsffi } = await loadWasm("test-worker");
  let calls = 0;
  const flaky = (exports) => {
    calls += 1;
    if (calls === 1) throw new Error("injected boot failure");
    return jsffi(exports);
  };
  const worker = makeWorker(wasmModule, flaky);

  const first = await worker.fetch(new Request(`${BASE}/hello`), {}, fakeCtx().ctx);
  assert.equal(first.status, 500);
  assert.match(await first.text(), /wasm boot failed: .*injected boot failure/);

  const second = await worker.fetch(new Request(`${BASE}/hello`), {}, fakeCtx().ctx);
  assert.equal(second.status, 200);
  assert.equal(await second.text(), "hello");
});
