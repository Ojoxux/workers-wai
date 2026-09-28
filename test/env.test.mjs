import { test } from "node:test";
import assert from "node:assert/strict";
import { BASE, fakeCtx, loadWorker } from "./harness.mjs";

const env = { GREETING: "hi", COUNT: 3 };

async function get(worker, path) {
  const { ctx } = fakeCtx();
  const res = await worker.fetch(new Request(`${BASE}${path}`), env, ctx);
  return { status: res.status, text: await res.text() };
}

const worker = await loadWorker("test-worker");

test("var returns a string entry", async () => {
  assert.deepEqual(await get(worker, "/env/var/GREETING"), { status: 200, text: "hi" });
});

test("var throws EnvMissing for an absent entry", async () => {
  const { status, text } = await get(worker, "/env/var/NOPE");
  assert.equal(status, 500);
  assert.match(text, /env: NOPE is not set/);
});

test("var throws EnvTypeMismatch for a non-string entry", async () => {
  const { status, text } = await get(worker, "/env/var/COUNT");
  assert.equal(status, 500);
  assert.match(text, /env: COUNT is a number, not a string/);
});

test("lookupVar returns Nothing for an absent entry", async () => {
  assert.equal((await get(worker, "/env/lookup/NOPE")).text, "Nothing");
  assert.equal((await get(worker, "/env/lookup/GREETING")).text, 'Just "hi"');
});

test("string entries are visible to lookupEnv", async () => {
  assert.equal((await get(worker, "/env/environ/GREETING")).text, 'Just "hi"');
  assert.equal((await get(worker, "/env/environ/COUNT")).text, "Nothing");
});

test("envAsEnviron: false keeps env out of the environ", async () => {
  const isolated = await loadWorker("test-worker", { envAsEnviron: false });
  assert.equal((await get(isolated, "/env/environ/GREETING")).text, "Nothing");
  assert.equal((await get(isolated, "/env/var/GREETING")).text, "hi");
});

test("lookupVar ignores inherited properties", async () => {
  assert.deepEqual(await get(worker, "/env/lookup/toString"), { status: 200, text: "Nothing" });
  assert.deepEqual(await get(worker, "/env/lookup/constructor"), { status: 200, text: "Nothing" });
});
