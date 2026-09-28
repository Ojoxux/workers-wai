import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { BASE, fakeCtx, loadWorker, startUpstream } from "./harness.mjs";

let upstream;
let worker;

before(async () => {
  upstream = await startUpstream();
  worker = await loadWorker("test-worker");
});
after(() => upstream.close());

test("waitUntil work finishes after the response", async () => {
  const { ctx, pending } = fakeCtx();
  const res = await worker.fetch(new Request(`${BASE}/wait/beacon`), { UPSTREAM: upstream.url }, ctx);
  assert.equal(await res.text(), "queued");
  assert.equal(pending.length, 1);
  await Promise.all(pending);
  assert.ok(upstream.hits.some((h) => h.url === "/beacon"));
});

test("waitUntil keeps the isolate alive after the response is sent", async () => {
  const { ctx, pending } = fakeCtx();
  const res = await worker.fetch(new Request(`${BASE}/wait/hold`), { UPSTREAM: upstream.url }, ctx);
  assert.equal(await res.text(), "queued");
  assert.equal(pending.length, 1);

  const timedOut = Symbol("timed out");
  const timeout = new Promise((resolve) => setTimeout(() => resolve(timedOut), 100));
  const outcome = await Promise.race([Promise.all(pending), timeout]);
  assert.equal(outcome, timedOut, "waitUntil work resolved before /hold was released");

  upstream.release();
  await Promise.all(pending);
  assert.ok(upstream.hits.some((h) => h.url === "/hold"));
});

test("an exception in waitUntil work is logged, not rethrown", async () => {
  const logged = [];
  const original = console.error;
  console.error = (...args) => logged.push(args.join(" "));
  try {
    const { ctx, pending } = fakeCtx();
    const res = await worker.fetch(new Request(`${BASE}/wait/fail`), {}, ctx);
    assert.equal(res.status, 200);
    await Promise.all(pending); // resolves: the failure does not reject
  } finally {
    console.error = original;
  }
  assert.ok(logged.some((line) => line.includes("waitUntil: user error (boom)")), logged.join("\n"));
});
