// yesod-core's default session backend (envClientSessionBackend, i.e. the
// real clientsession package) on Workers, through test-yesod.

import { test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { BASE, fakeCtx, loadWorker } from "./harness.mjs";
import { sessionSetCookie, cookieValue } from "./session-cookie.mjs";

// clientsession keys are 96 bytes, base64-encoded in the environment.
const env = { SESSION_BACKEND: "clientsession", SESSION_KEY: randomBytes(96).toString("base64") };
const worker = await loadWorker("test-yesod", { exposeErrors: true });

async function send(path, { cookie, method = "GET", headers = {} } = {}) {
  const h = new Headers(headers);
  if (cookie) h.set("cookie", cookie);
  const res = await worker.fetch(new Request(`${BASE}${path}`, { method, headers: h }), env, fakeCtx().ctx);
  return { res, status: res.status, text: await res.text() };
}

test("envClientSessionBackend keeps the session across requests", async () => {
  const first = await send("/count");
  assert.equal(first.text, "1");
  const cookie = `_SESSION=${cookieValue(sessionSetCookie(first.res))}`;
  assert.equal((await send("/count", { cookie })).text, "2");
});

test("CSRF works on envClientSessionBackend", async () => {
  const form = await send("/form");
  const cookie = `_SESSION=${cookieValue(sessionSetCookie(form.res))}`;
  assert.equal((await send("/form", { method: "POST", cookie })).status, 403);
  const ok = await send("/form", { method: "POST", cookie, headers: { "X-XSRF-TOKEN": form.text } });
  assert.equal(ok.status, 200);
});
