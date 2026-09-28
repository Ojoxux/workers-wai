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

async function send(path, init) {
  const { ctx } = fakeCtx();
  return worker.fetch(new Request(`${BASE}${path}`, init), { UPSTREAM: upstream.url }, ctx);
}

test("method, headers and body reach the upstream", async () => {
  const res = await send("/fetch/roundtrip");
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { method: "PUT", xtest: "hello", body: "payload" });
});

test("4xx and 5xx are responses, not exceptions", async () => {
  assert.equal(await (await send("/fetch/status/404")).text(), "status=404");
  assert.equal(await (await send("/fetch/status/503")).text(), "status=503");
});

test("a proxied request streams its body and returns the upstream response", async () => {
  const res = await send("/fetch/proxy", { method: "POST", body: "streamed" });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("x-upstream"), "yes");
  assert.deepEqual(await res.json(), { method: "POST", xtest: null, body: "streamed" });
});

test("a network failure throws FetchException", async () => {
  const res = await send("/fetch/unreachable");
  assert.equal(res.status, 500);
  assert.match(await res.text(), /fetch http:\/\/127\.0\.0\.1:1\/ failed: TypeError/);
});

test("a JS exception keeps its name", async () => {
  const res = await send("/fetch/badurl");
  assert.equal(res.status, 500);
  assert.match(await res.text(), /fetch not a url failed: TypeError: /);
});
