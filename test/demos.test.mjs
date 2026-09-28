import { test } from "node:test";
import assert from "node:assert/strict";
import { BASE, fakeCtx, loadWorker } from "./harness.mjs";

const wai = await loadWorker("demo-wai");
const yesod = await loadWorker("demo-yesod");

async function send(worker, path, init) {
  const res = await worker.fetch(new Request(`${BASE}${path}`, init), {}, fakeCtx().ctx);
  return { status: res.status, text: await res.text() };
}

test("demo-wai: root", async () => {
  assert.deepEqual(await send(wai, "/"), { status: 200, text: "Hello from WAI on Cloudflare Workers" });
});

test("demo-wai: path, query and headers", async () => {
  const { status, text } = await send(wai, "/a/b?x=1&y=2", {
    headers: { "X-Demo": "yes", "CF-Connecting-IP": "203.0.113.7" },
  });
  assert.equal(status, 200);
  assert.match(text, /^rawPathInfo: \/a\/b$/m);
  assert.match(text, /^pathInfo: \["a","b"\]$/m);
  assert.match(text, /^rawQueryString: \?x=1&y=2$/m);
  assert.match(text, /^isSecure: False$/m);
  assert.match(text, /^remoteHost: 203\.0\.113\.7:0$/m);
  assert.match(text, /^ {2}x-demo: yes$/m);
});

test("demo-wai: POST body", async () => {
  const { text } = await send(wai, "/echo", {
    method: "POST",
    headers: { "Content-Type": "text/plain" },
    body: "hello body",
  });
  assert.match(text, /^bodyLength: 10$/m);
  assert.match(text, /^body: hello body$/m);
});

test("demo-wai: HEAD", async () => {
  assert.equal((await send(wai, "/", { method: "HEAD" })).status, 200);
});

test("demo-wai: responseStream is buffered", async () => {
  assert.deepEqual(await send(wai, "/stream"), { status: 200, text: "chunk one\nchunk two\n" });
});

test("demo-wai: the ExecutionContext is in the vault", async () => {
  assert.deepEqual(await send(wai, "/ctx"), { status: 200, text: "context: yes" });
});

test("demo-yesod: routes, templates and 404", async () => {
  const home = await send(yesod, "/");
  assert.equal(home.status, 200);
  assert.match(home.text, /Hello from Yesod on Cloudflare Workers/);

  const hello = await send(yesod, "/hello/world");
  assert.equal(hello.status, 200);
  assert.match(hello.text, /Hello, world!/);

  assert.equal((await send(yesod, "/nope")).status, 404);
});
