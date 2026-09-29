// Multiple Set-Cookie headers, and header combination generally, survive the
// JS boundary in every direction: built in Haskell, fetched from upstream,
// proxied straight through, and read off an inbound request.
//
// Per the Fetch spec, iterating a Headers object yields each set-cookie
// separately but joins other duplicate headers with ", ".
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

test("a response built in Haskell keeps both Set-Cookie headers", async () => {
  const res = await send("/cookies/set");
  assert.deepEqual(res.headers.getSetCookie(), ["a=1; Path=/", "b=2; Path=/"]);
});

test("a fetched response keeps both Set-Cookie headers", async () => {
  const res = await send("/cookies/fetched");
  assert.equal(await res.text(), "x=1|y=2");
});

test("a proxied fetched response keeps both Set-Cookie headers", async () => {
  const res = await send("/cookies/proxy");
  assert.deepEqual(res.headers.getSetCookie(), ["x=1", "y=2"]);
});

test("inbound request headers: set-cookie stays separate, other duplicates combine", async () => {
  const res = await send("/headers/echo", {
    headers: new Headers([
      ["cookie", "a=1; b=2"],
      ["x-multi", "1"],
      ["x-multi", "2"],
    ]),
  });
  const body = await res.text();
  const lines = body.split("\n");
  assert.ok(lines.includes("cookie: a=1; b=2"));
  assert.ok(lines.includes("x-multi: 1, 2"));
});
