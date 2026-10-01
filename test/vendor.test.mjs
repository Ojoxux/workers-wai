// The vendored crypto stack (haskell/vendor) checked against published
// known-answer vectors, through the test-vendor Worker.

import { test } from "node:test";
import assert from "node:assert/strict";
import { BASE, fakeCtx, loadWorker } from "./harness.mjs";

const worker = await loadWorker("test-vendor", { exposeErrors: true });

async function get(path) {
  const res = await worker.fetch(new Request(`${BASE}${path}`), {}, fakeCtx().ctx);
  return { status: res.status, text: await res.text() };
}

test("crypton, memory and cborg match their known-answer vectors", async () => {
  const { status, text } = await get("/vectors");
  assert.equal(status, 200, text);
  assert.equal(text, "ok 67");
});

test("crypton's random bytes come from the host and differ per call", async () => {
  const a = await get("/random");
  const b = await get("/random");
  assert.equal(a.status, 200, a.text);
  assert.match(a.text, /^[0-9a-f]{64}$/);
  assert.notEqual(a.text, b.text);
});

test("the real clientsession encrypts, decrypts and rejects tampering", async () => {
  const { status, text } = await get("/clientsession");
  assert.equal(status, 200, text);
  assert.equal(text, "ok");
});

test("yesod-auth with the GitHub OAuth2 plugin boots and renders its login page", async () => {
  const { status, text } = await get("/auth/login");
  assert.equal(status, 200, text);
  assert.match(text, /\/auth\/page\/github\/forward/);
});
