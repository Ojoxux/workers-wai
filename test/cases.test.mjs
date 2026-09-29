import { test } from "node:test";
import assert from "node:assert/strict";
import { cases, check, env } from "./cases.mjs";
import { BASE, fakeCtx, loadWorker } from "./harness.mjs";

// exposeErrors: several tests assert on the exception text in 500 bodies.
const worker = await loadWorker("test-worker", { exposeErrors: true });
const send = (path, init) => worker.fetch(new Request(`${BASE}${path}`, init), env, fakeCtx().ctx);

for (const c of cases) {
  test(`case: ${c.name}`, async () => {
    assert.deepEqual(await check(send, c), []);
  });
}
