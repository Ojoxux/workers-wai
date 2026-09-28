import { test } from "node:test";
import assert from "node:assert/strict";
import { BASE, fakeCtx, loadWorker } from "./harness.mjs";

const worker = await loadWorker("test-worker");

async function send(path, init) {
  const { ctx } = fakeCtx();
  return worker.fetch(new Request(`${BASE}${path}`, init), {}, ctx);
}

test("bytes reads the request body", async () => {
  const res = await send("/body/echo", { method: "POST", body: "hello body" });
  assert.equal(res.status, 200);
  assert.equal(await res.text(), "hello body");
});

test("a bodyless request reads as empty", async () => {
  const res = await send("/body/echo");
  assert.equal(res.status, 200);
  assert.equal(await res.text(), "");
});

test("text decodes UTF-8", async () => {
  const res = await send("/body/text", { method: "POST", body: "héllo, 世界" });
  assert.equal(await res.text(), "héllo, 世界");
});

test("a second read throws BodyAlreadyUsed", async () => {
  const res = await send("/body/twice", { method: "POST", body: "x" });
  assert.equal(res.status, 500);
  assert.match(await res.text(), /BodyAlreadyUsed/);
});

test("forwarding a body after reading it throws BodyAlreadyUsed", async () => {
  const res = await send("/body/forward-after-read", { method: "POST", body: "x" });
  assert.equal(res.status, 500);
  assert.match(await res.text(), /BodyAlreadyUsed/);
});
