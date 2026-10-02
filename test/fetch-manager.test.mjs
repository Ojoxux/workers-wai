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

test("redirects are http-client's to follow, not fetch's", async () => {
  // With redirect following off in http-client, the 302 itself must come back.
  const raw = await http({ url: `${upstream.url}/redirect`, redirects: "0" });
  assert.equal(raw.status, "302");
  assert.ok(raw.headers.includes("location: /echo-all"), raw.headers.join("\n"));
  // With it on, http-client follows: two requests reach the upstream.
  const before = upstream.hits.length;
  const followed = await http({ url: `${upstream.url}/redirect` });
  assert.equal(followed.status, "200");
  assert.deepEqual(upstream.hits.slice(before).map((h) => h.url), ["/redirect", "/echo-all"]);
});

test("a gzip response is decompressed once", async () => {
  const r = await http({ url: `${upstream.url}/gzip` });
  assert.equal(r.status, "200");
  assert.equal(r.body, "hello gzip");
  assert.ok(!r.headers.some((h) => h.startsWith("content-encoding")), r.headers.join("\n"));
});

test("multiple Set-Cookie headers stay separate", async () => {
  const r = await http({ url: `${upstream.url}/cookies` });
  assert.deepEqual(r.headers.filter((h) => h.startsWith("set-cookie")), ["set-cookie: x=1", "set-cookie: y=2"]);
});

test("a failed fetch is an HttpException ConnectionFailure", async () => {
  const r = await worker.fetch(new Request(`${BASE}/http?url=${encodeURIComponent("http://127.0.0.1:1/")}`), {}, fakeCtx().ctx);
  assert.match(await r.text(), /^exception ConnectionFailure/);
});

test("Expect: 100-continue is rejected with a clear message", async () => {
  const q = new URLSearchParams({ url: `${upstream.url}/echo-all`, method: "POST", body: "x", expect: "100-continue" }).toString();
  const r = await worker.fetch(new Request(`${BASE}/http?${q}`), {}, fakeCtx().ctx);
  assert.match(await r.text(), /^exception InternalException.*100-continue/s);
});

test("a HEAD response keeps the upstream Content-Length", async () => {
  const head = await http({ url: `${upstream.url}/sized`, method: "HEAD" });
  assert.equal(head.status, "200");
  assert.ok(head.headers.includes("content-length: 10"), head.headers.join("\n"));
  assert.equal(head.body, "");
  const get = await http({ url: `${upstream.url}/sized` });
  assert.ok(get.headers.includes("content-length: 10"), get.headers.join("\n"));
  assert.equal(get.body, "0123456789");
});

test("a raw path with a space or non-ASCII bytes is percent-encoded once", async () => {
  const spaced = await http({ url: upstream.url, rawPath: "/echo-all?q=a b" });
  assert.equal(JSON.parse(spaced.body).url, "/echo-all?q=a%20b");
  const accented = await http({ url: upstream.url, rawPath: "/echo-all?q=é" });
  assert.equal(JSON.parse(accented.body).url, "/echo-all?q=%C3%A9");
});

test("a proxied (absolute-form) request is rejected with a clear message", async () => {
  const q = new URLSearchParams({ url: `${upstream.url}/echo-all`, proxy: "1" }).toString();
  const r = await worker.fetch(new Request(`${BASE}/http?${q}`), {}, fakeCtx().ctx);
  assert.match(await r.text(), /^exception InternalException.*not origin-form.*does not support proxies/s);
});

test("a query string reaches the upstream", async () => {
  const r = await http({ url: `${upstream.url}/echo-all?a=1&b=2` });
  assert.equal(JSON.parse(r.body).url, "/echo-all?a=1&b=2");
});

test("an empty-body POST arrives as a POST with an empty body", async () => {
  const r = await http({ url: `${upstream.url}/echo-all`, method: "POST" });
  const seen = JSON.parse(r.body);
  assert.equal(seen.method, "POST");
  assert.equal(seen.body, "");
});

/** Runs one http-client request inside the Worker; returns the raw summary text. */
async function httpText(params) {
  const q = new URLSearchParams(params).toString();
  return (await worker.fetch(new Request(`${BASE}/http?${q}`), {}, fakeCtx().ctx)).text();
}

test("a failure while reading the response body is an HttpException ConnectionFailure", async () => {
  assert.match(await httpText({ url: `${upstream.url}/broken-body` }), /^exception ConnectionFailure/);
});

test("# and \\ in a raw path are percent-encoded, not taken as fragment or separator", async () => {
  const hashed = await http({ url: upstream.url, rawPath: "/echo-all?q=a#b" });
  assert.equal(JSON.parse(hashed.body).url, "/echo-all?q=a%23b");
  const slashed = await http({ url: upstream.url, rawPath: "/echo-all?q=a\\b" });
  assert.equal(JSON.parse(slashed.body).url, "/echo-all?q=a%5Cb");
});

test("an https request through a proxy is rejected with a clear message", async () => {
  const text = await httpText({ url: "https://127.0.0.1:1/", proxy: "1" });
  assert.match(text, /^exception InternalException.*does not support proxies/s);
});

test("only an Expect value of exactly 100-continue is rejected", async () => {
  const r = await http({ url: `${upstream.url}/echo-all`, method: "POST", body: "x", expect: "100-Continue" });
  assert.equal(r.status, "200");
  assert.equal(JSON.parse(r.body).body, "x");
});

test("a 204 response gets no Content-Length and an empty body", async () => {
  const r = await http({ url: `${upstream.url}/status/204` });
  assert.equal(r.status, "204");
  assert.ok(!r.headers.some((h) => h.startsWith("content-length")), r.headers.join("\n"));
  assert.equal(r.body, "");
});

test("a 304 response keeps the upstream Content-Length and has an empty body", async () => {
  const r = await http({ url: `${upstream.url}/not-modified` });
  assert.equal(r.status, "304");
  assert.ok(r.headers.includes("content-length: 5"), r.headers.join("\n"));
  assert.equal(r.body, "");
});
