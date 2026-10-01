// http-client's Manager over fetch (http-client-cloudflare), driven through
// test-vendor's /http route against a local upstream.

import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { BASE, fakeCtx, loadWorker, startUpstream } from "./harness.mjs";

let upstream;
let worker;
before(async () => {
  upstream = await startUpstream();
  worker = await loadWorker("test-vendor", { exposeErrors: true });
});
after(() => upstream.close());

/** Runs one http-client request inside the Worker; returns its summary. */
async function http(params) {
  const q = new URLSearchParams(params).toString();
  const res = await worker.fetch(new Request(`${BASE}/http?${q}`), {}, fakeCtx().ctx);
  const text = await res.text();
  assert.equal(res.status, 200, text);
  const [head, ...rest] = text.split("\n\n");
  const [status, ...headerLines] = head.split("\n");
  return { status, headers: headerLines, body: rest.join("\n\n") };
}

test("GET reaches the upstream and returns status, headers and body", async () => {
  const r = await http({ url: `${upstream.url}/echo-all` });
  assert.equal(r.status, "200");
  assert.ok(r.headers.includes("x-upstream: yes"), r.headers.join("\n"));
  const seen = JSON.parse(r.body);
  assert.equal(seen.method, "GET");
  assert.equal(seen.url, "/echo-all");
});

test("a form POST with Content-Length arrives intact (hoauth2's token request shape)", async () => {
  const r = await http({
    url: `${upstream.url}/echo-all`,
    method: "POST",
    contentType: "application/x-www-form-urlencoded",
    body: "grant_type=authorization_code&code=abc123",
  });
  const seen = JSON.parse(r.body);
  assert.equal(seen.method, "POST");
  assert.equal(seen.headers["content-type"], "application/x-www-form-urlencoded");
  assert.equal(seen.body, "grant_type=authorization_code&code=abc123");
});

test("a chunked request body is reassembled", async () => {
  const r = await http({ url: `${upstream.url}/echo-all`, method: "POST", mode: "chunked", body: "one,two,three" });
  assert.equal(JSON.parse(r.body).body, "one,two,three");
});

test("Accept and basic auth headers reach the upstream", async () => {
  const r = await http({ url: `${upstream.url}/echo-all`, accept: "application/json", basic: "user:pass" });
  const seen = JSON.parse(r.body);
  assert.equal(seen.headers.accept, "application/json");
  assert.equal(seen.headers.authorization, "Basic dXNlcjpwYXNz");
});

test("a 404 is a response, not an exception", async () => {
  assert.equal((await http({ url: `${upstream.url}/status/404` })).status, "404");
});
