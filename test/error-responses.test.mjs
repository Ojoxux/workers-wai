// What a client sees when a request fails: by default only a generic 500 and
// a ray id, with the details in console.error under the same id; with
// exposeErrors the details are in the body too.

import { test } from "node:test";
import assert from "node:assert/strict";
import { makeWorker } from "../worker/src/runtime.mjs";
import { BASE, fakeCtx, loadWasm, loadWorker } from "./harness.mjs";

/** Run `fn` with console.error captured; returns [result, logged lines]. */
async function capturingErrors(fn) {
  const logged = [];
  const original = console.error;
  console.error = (...args) => logged.push(args.join(" "));
  try {
    return [await fn(), logged.join("\n")];
  } finally {
    console.error = original;
  }
}

async function get(worker, path, headers = {}) {
  const res = await worker.fetch(new Request(`${BASE}${path}`, { headers }), {}, fakeCtx().ctx);
  return { status: res.status, type: res.headers.get("content-type"), text: await res.text() };
}

const worker = await loadWorker("test-worker");

test("an exception becomes a generic 500 carrying the cf-ray id", async () => {
  const [res, logged] = await capturingErrors(() =>
    get(worker, "/env/var/NOPE", { "cf-ray": "test-ray-1" }),
  );
  assert.equal(res.status, 500);
  assert.equal(res.type, "text/plain; charset=utf-8");
  assert.equal(res.text, "Internal Server Error\nray: test-ray-1\n");
  assert.ok(!res.text.includes("NOPE"));
  assert.match(logged, /env: NOPE is not set/);
  assert.match(logged, /test-ray-1/);
});

test("without cf-ray a generated id links the body to the log", async () => {
  const [res, logged] = await capturingErrors(() => get(worker, "/env/var/NOPE"));
  assert.equal(res.status, 500);
  const m = res.text.match(/^Internal Server Error\nray: (\S+)\n$/);
  assert.ok(m, JSON.stringify(res.text));
  assert.ok(logged.includes(m[1]), logged);
  assert.match(logged, /env: NOPE is not set/);
});

test("exposeErrors: true puts the details in the body", async () => {
  const exposing = await loadWorker("test-worker", { exposeErrors: true });
  const [res] = await capturingErrors(() =>
    get(exposing, "/env/var/NOPE", { "cf-ray": "test-ray-1" }),
  );
  assert.equal(res.status, 500);
  assert.match(res.text, /env: NOPE is not set/);
  assert.match(res.text, /ray: test-ray-1/);
});

function flakyJsffi(jsffi) {
  let calls = 0;
  return (exports) => {
    calls += 1;
    if (calls === 1) throw new Error("injected boot failure");
    return jsffi(exports);
  };
}

test("a failed boot becomes a generic 500 and is still retried", async () => {
  const { wasmModule, jsffi } = await loadWasm("test-worker");
  const booting = makeWorker(wasmModule, flakyJsffi(jsffi));

  const [first, logged] = await capturingErrors(() =>
    get(booting, "/hello", { "cf-ray": "test-ray-2" }),
  );
  assert.equal(first.status, 500);
  assert.equal(first.text, "Internal Server Error\nray: test-ray-2\n");
  assert.ok(!first.text.includes("injected boot failure"));
  assert.match(logged, /injected boot failure/);
  assert.match(logged, /test-ray-2/);

  const second = await get(booting, "/hello");
  assert.equal(second.status, 200);
  assert.equal(second.text, "hello");
});

test("exposeErrors: true keeps the boot stack in the body", async () => {
  const { wasmModule, jsffi } = await loadWasm("test-worker");
  const booting = makeWorker(wasmModule, flakyJsffi(jsffi), { exposeErrors: true });

  const [first] = await capturingErrors(() => get(booting, "/hello", { "cf-ray": "test-ray-3" }));
  assert.equal(first.status, 500);
  assert.match(first.text, /wasm boot failed: .*injected boot failure/);
  assert.match(first.text, /ray: test-ray-3\n$/);
});
