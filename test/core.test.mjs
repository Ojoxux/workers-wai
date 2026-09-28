import { test } from "node:test";
import assert from "node:assert/strict";
import { BASE, fakeCtx, loadWorker } from "./harness.mjs";

const worker = await loadWorker("test-worker");

test("serves a response built in Haskell", async () => {
  const { ctx } = fakeCtx();
  const res = await worker.fetch(new Request(`${BASE}/hello`), {}, ctx);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("content-type"), "text/plain; charset=utf-8");
  assert.equal(await res.text(), "hello");
});

test("null-body statuses get a null body", async () => {
  const { ctx } = fakeCtx();
  const res = await worker.fetch(new Request(`${BASE}/status/204`), {}, ctx);
  assert.equal(res.status, 204);
  assert.equal(res.body, null);
});

test("unknown routes are 404", async () => {
  const { ctx } = fakeCtx();
  const res = await worker.fetch(new Request(`${BASE}/nope`), {}, ctx);
  assert.equal(res.status, 404);
  assert.equal(await res.text(), "not found");
});
