// Run test-worker under `wrangler dev` (workerd) and check it over HTTP:
// the shared table in test/cases.mjs, plus workerd-only checks that need an
// upstream server (outbound fetch, Set-Cookie passthrough, waitUntil). It also
// starts test/yesod-wrangler.toml (test-yesod) and checks sessions, CSRF,
// yesod-static routes served by Workers Static Assets, and
// persistent on its own local D1, and
// test/vendor-wrangler.toml (test-vendor) and checks the vendored crypto stack and
// http-client's Manager over fetch (GET, form POST, redirects, gzip, failures).
// test-worker also gets the local D1 of test/wrangler.toml (binding DB), against
// which the D1 checks run: Node has no D1, so they exist only here.
//
//   node scripts/check-wrangler.mjs
//   SHOW_WRANGLER_LOG=1 node scripts/check-wrangler.mjs   # print the log even on success
//
// Requires builds of test-worker, test-yesod and test-vendor in .test-build/ first: run scripts/test.sh, or
// scripts/build.sh <target> .test-build/<target> for each.
//
// The script starts the upstream from test/harness.mjs and the three wranglers itself,
// and always stops them on exit, failure or Ctrl-C.

import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { cases, check } from "../test/cases.mjs";
import { startUpstream } from "../test/harness.mjs";
import { cookieValue, sessionSetCookie } from "../test/session-cookie.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const READY_TIMEOUT_MS = 60_000;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function freePort() {
  return new Promise((resolve, reject) => {
    const s = createServer();
    s.once("error", reject);
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

// --- start upstream and wrangler -------------------------------------------

const upstream = await startUpstream();
function startWrangler(config, extraArgs, readyPath) {
  const instance = { log: "", exited: false, base: null, proc: null, readyPath };
  instance.start = async () => {
    const port = await freePort();
    const inspectorPort = await freePort(); // the default 9229 collides between instances
    instance.base = `http://127.0.0.1:${port}`;
    instance.proc = spawn(
      join(root, "worker/node_modules/.bin/wrangler"),
      ["dev", "-c", config, "--port", String(port), "--ip", "127.0.0.1", "--inspector-port", String(inspectorPort),
       // own state dir: instances sharing the local SQLite persist state lock each other out (SQLITE_BUSY)
       "--persist-to", join(root, ".wrangler", "state", basename(config, ".toml")), ...extraArgs],
      {
        cwd: root,
        detached: true, // own process group, so workerd dies with it
        stdio: ["ignore", "pipe", "pipe"],
        env: { ...process.env, WRANGLER_SEND_METRICS: "false", CI: "1" },
      },
    );
    instance.proc.stdout.on("data", (d) => (instance.log += d));
    instance.proc.stderr.on("data", (d) => (instance.log += d));
    instance.proc.on("exit", () => (instance.exited = true));
  };
  instance.stop = async () => {
    if (!instance.proc || instance.exited) return;
    try { process.kill(-instance.proc.pid, "SIGTERM"); } catch {}
    for (let i = 0; i < 50 && !instance.exited; i++) await sleep(100);
    try { process.kill(-instance.proc.pid, "SIGKILL"); } catch {}
  };
  instance.waitReady = async () => {
    const deadline = Date.now() + READY_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (instance.exited) throw new Error(`wrangler (${config}) exited before becoming ready`);
      try {
        const res = await fetch(`${instance.base}${instance.readyPath}`);
        if (res.status === 200) return;
      } catch {}
      await sleep(250);
    }
    throw new Error(`wrangler (${config}) not ready after ${READY_TIMEOUT_MS / 1000}s`);
  };
  return instance;
}

const workers = startWrangler("test/wrangler.toml", ["--var", `UPSTREAM:${upstream.url}`], "/hello");
const yesod = startWrangler("test/yesod-wrangler.toml", [], "/count");
const vendor = startWrangler("test/vendor-wrangler.toml", [], "/vectors");
await workers.start();
await yesod.start();
await vendor.start();

let cleanedUp = false;
async function cleanup() {
  if (cleanedUp) return;
  cleanedUp = true;
  upstream.release();
  await Promise.all([workers.stop(), yesod.stop(), vendor.stop()]);
  await upstream.close();
}
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, async () => {
    await cleanup();
    process.exit(130);
  });
}

// --- upstream-dependent checks (workerd only; Node covers them in
// fetch/context/headers.test.mjs with the same expectations) ----------------

const send = (path, init) => fetch(`${workers.base}${path}`, init);

function expectEqual(problems, what, actual, expected) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    problems.push(`${what} ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`);
  }
}

async function waitForHit(url, ms) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (upstream.hits.some((h) => h.url === url)) return true;
    await sleep(50);
  }
  return false;
}

const upstreamChecks = [
  ["fetch roundtrip", async (p) => {
    const res = await send("/fetch/roundtrip");
    expectEqual(p, "status", res.status, 200);
    expectEqual(p, "body", await res.json().catch((e) => String(e)), { method: "PUT", xtest: "hello", body: "payload" });
  }],
  ["fetch 4xx is a response", async (p) => {
    expectEqual(p, "body", await (await send("/fetch/status/404")).text(), "status=404");
  }],
  ["fetch proxy streams body", async (p) => {
    const res = await send("/fetch/proxy", { method: "POST", body: "streamed" });
    expectEqual(p, "status", res.status, 200);
    expectEqual(p, "x-upstream", res.headers.get("x-upstream"), "yes");
    expectEqual(p, "body", await res.json().catch((e) => String(e)), { method: "POST", xtest: null, body: "streamed" });
  }],
  ["fetch rewrite drops content-length", async (p) => {
    const res = await send("/fetch/rewrite", {
      method: "POST",
      headers: { "content-length": "13" },
      body: "original body",
    });
    expectEqual(p, "status", res.status, 200);
    expectEqual(p, "body", await res.json().catch((e) => String(e)), { method: "POST", xtest: null, body: "rewritten" });
  }],
  ["cookies set in Haskell", async (p) => {
    const res = await send("/cookies/set");
    expectEqual(p, "set-cookie", res.headers.getSetCookie(), ["a=1; Path=/", "b=2; Path=/"]);
  }],
  ["cookies fetched", async (p) => {
    expectEqual(p, "body", await (await send("/cookies/fetched")).text(), "x=1|y=2");
  }],
  ["cookies proxied", async (p) => {
    const res = await send("/cookies/proxy");
    expectEqual(p, "set-cookie", res.headers.getSetCookie(), ["x=1", "y=2"]);
  }],
  ["waitUntil fetch runs after the response", async (p) => {
    const res = await send("/wait/beacon");
    expectEqual(p, "body", await res.text(), "queued");
    if (!(await waitForHit("/beacon", 5000))) p.push("upstream saw no /beacon within 5s");
  }],
  ["waitUntil work outlives the response", async (p) => {
    const res = await send("/wait/hold");
    expectEqual(p, "body", await res.text(), "queued");
    // The response is in hand; /hold must be pending at the upstream now.
    if (!(await waitForHit("/hold", 5000))) p.push("upstream saw no /hold within 5s");
    const logBefore = workers.log.length;
    upstream.release();
    await sleep(1000);
    const after = workers.log.slice(logBefore);
    // Narrow on purpose: late "unhandled exception" lines from earlier intentional-500 cases
    // also land in this log and do not match. Any "waitUntil" line fails the check: a
    // failure logs "waitUntil:" (see the next check), and workerd's own "waitUntil() tasks
    // did not complete ... cancelled" warning contains the word too.
    if (/waitUntil|uncaught/i.test(after)) p.push(`wrangler logged after release:\n${after}`);
  }],
  // Shows that the log check above would see a waitUntil failure.
  ["waitUntil failure is logged", async (p) => {
    const res = await send("/wait/fail");
    expectEqual(p, "status", res.status, 200);
    const deadline = Date.now() + 5000;
    while (!workers.log.includes("waitUntil: user error (boom)") && Date.now() < deadline) await sleep(50);
    if (!workers.log.includes("waitUntil: user error (boom)")) p.push("wrangler log has no \"waitUntil: user error (boom)\"");
  }],
];

// --- session checks against test-yesod (Node covers the same in
// test/session.test.mjs) ------------------------------------------------------

const sendYesod = (path, init) => fetch(`${yesod.base}${path}`, init);

const sessionChecks = [
  ["session survives with its cookie", async (problems) => {
    const first = await sendYesod("/count");
    expectEqual(problems, "first count", await first.text(), "1");
    const cookie = `_SESSION=${cookieValue(sessionSetCookie(first))}`;
    const second = await sendYesod("/count", { headers: { cookie } });
    expectEqual(problems, "second count", await second.text(), "2");
  }],
  ["CSRF rejects a POST without the token and accepts it with", async (problems) => {
    const form = await sendYesod("/form");
    const token = await form.text();
    const cookie = `_SESSION=${cookieValue(sessionSetCookie(form))}`;
    const rejected = await sendYesod("/form", { method: "POST", headers: { cookie } });
    expectEqual(problems, "status without token", rejected.status, 403);
    const accepted = await sendYesod("/form", { method: "POST", headers: { cookie, "X-XSRF-TOKEN": token } });
    expectEqual(problems, "status with token", accepted.status, 200);
  }],
];

// --- yesod-static routes served by Workers Static Assets (workerd only) ----

const staticChecks = [
  ["yesod-static URLs are served by Workers Static Assets", async (p) => {
    const urls = (await (await sendYesod("/static-url")).text()).trim().split("\n");
    const expected = [
      ["/static/app.js", "text/javascript", "window.testYesodStatic"],
      ["/static/img/dot.png", "image/png", null],
    ];
    expectEqual(p, "url count", urls.length, expected.length);
    for (const [i, [path, type, prefix]] of expected.entries()) {
      const url = new URL(urls[i] ?? "", yesod.base);
      expectEqual(p, `path ${i}`, url.pathname, path);
      if (!/^\?etag=[\w-]+/.test(url.search)) p.push(`${path}: no etag query in ${urls[i]}`);
      const r = await sendYesod(url.pathname + url.search);
      expectEqual(p, `${path} status`, r.status, 200);
      if (!(r.headers.get("content-type") ?? "").startsWith(type)) p.push(`${path}: content-type ${r.headers.get("content-type")}`);
      expectEqual(p, `${path} cache-control`, r.headers.get("cache-control"), "public, max-age=31536000, immutable");
      const body = await r.text();
      if (prefix && !body.startsWith(prefix)) p.push(`${path}: body ${body.slice(0, 60)}`);
    }
  }],
  ["a missing static file reaches the Worker and gets a 404", async (p) => {
    const r = await sendYesod("/static/missing.js?etag=x");
    expectEqual(p, "status", r.status, 404);
    await r.text();
  }],
];

// --- persistent on D1 (test-yesod's local DB; workerd only) ---------------

const persistChecks = [
  ["persistent migration creates the table", async (p) => {
    const before = await (await sendYesod("/persist/migration")).text();
    if (!/CREATE TABLE/i.test(before) && before !== "") p.push(`unexpected migration: ${before}`);
    const setup = await sendYesod("/persist/setup");
    expectEqual(p, "setup status", setup.status, 200);
    expectEqual(p, "migration after setup", await (await sendYesod("/persist/migration")).text(), "");
  }],
  ["persistent CRUD", async (p) => {
    const r = await sendYesod("/persist/crud");
    expectEqual(p, "status", r.status, 200);
    expectEqual(p, "body", await r.text(), "get=one top=three updated=10 count=2");
  }],
  ["persistent migration that rebuilds a table keeps its rows", async (p) => {
    expectEqual(p, "body", await (await sendYesod("/persist/rebuild")).text(), "steps=6 rows=kept:0 left=0");
  }],
  ["persistent inserts under concurrency get their own ids", async (p) => {
    const titles = Array.from({ length: 20 }, (_, i) => `conc-${Date.now()}-${i}`);
    const bodies = await Promise.all(titles.map((t) => sendYesod(`/persist/insert/${t}`).then((r) => r.text())));
    titles.forEach((t, i) => { if (bodies[i] !== t) p.push(`${t} read back as ${bodies[i]}`); });
  }],
  ["persistent field types round-trip", async (p) => {
    expectEqual(p, "body", await (await sendYesod("/persist/types")).text(), "ok");
  }],
  ["persistent unique constraint", async (p) => {
    expectEqual(p, "body", await (await sendYesod("/persist/unique")).text(), "rejected stored=1");
  }],
  ["persistent bulk writes past 100 parameters", async (p) => {
    expectEqual(p, "body", await (await sendYesod("/persist/bulk")).text(),
      "count=50 reps=15 counts=1,1100,5000 unchunked=rejected");
  }],
  ["persistent through createD1Pool and runSqlPool", async (p) => {
    expectEqual(p, "body", await (await sendYesod("/persist/pool")).text(), "pooled");
  }],
];

// --- vendored crypto stack against test-vendor (Node covers the same in
// test/vendor.test.mjs) ----------------------------------------------------

const sendVendor = (path, init) => fetch(`${vendor.base}${path}`, init);

const vendorChecks = [
  ["vendored crypto and CBOR vectors", async (problems) => {
    const res = await sendVendor("/vectors");
    expectEqual(problems, "vectors", await res.text(), "ok 77");
  }],
  ["crypton randomness via random_get", async (problems) => {
    const a = await (await sendVendor("/random")).text();
    const b = await (await sendVendor("/random")).text();
    if (!/^[0-9a-f]{64}$/.test(a)) problems.push(`random ${JSON.stringify(a)}`);
    if (a === b) problems.push("two random draws were equal");
  }],
  ["real clientsession round trip", async (problems) => {
    expectEqual(problems, "clientsession", await (await sendVendor("/clientsession")).text(), "ok");
  }],
  ["yesod-auth login page", async (problems) => {
    const res = await sendVendor("/auth/login");
    expectEqual(problems, "status", res.status, 200);
    if (!/\/auth\/page\/github\/forward/.test(await res.text())) problems.push("no GitHub login link");
  }],
];

// --- http-client over fetch (Node covers the same in test/fetch-manager.test.mjs)

// Also records a problem unless the /http route itself answered 200; its text
// carries the Manager's result.
async function viaManager(p, params) {
  const res = await sendVendor(`/http?${new URLSearchParams(params)}`);
  const text = await res.text();
  const [head, ...rest] = text.split("\n\n");
  const [status, ...headers] = head.split("\n");
  if (res.status !== 200) p.push(`route returned ${res.status}: ${text}`);
  return { text, status, headers, body: rest.join("\n\n") };
}

const managerChecks = [
  ["manager GET", async (p) => {
    const r = await viaManager(p, { url: `${upstream.url}/echo-all` });
    expectEqual(p, "status", r.status, "200");
    if (r.status === "200") expectEqual(p, "method", JSON.parse(r.body).method, "GET");
  }],
  ["manager form POST", async (p) => {
    const r = await viaManager(p, { url: `${upstream.url}/echo-all`, method: "POST", contentType: "application/x-www-form-urlencoded", body: "a=1&b=2" });
    if (r.status !== "200") return p.push(r.text);
    expectEqual(p, "body", JSON.parse(r.body).body, "a=1&b=2");
  }],
  ["manager leaves redirects to http-client", async (p) => {
    const r = await viaManager(p, { url: `${upstream.url}/redirect`, redirects: "0" });
    expectEqual(p, "status", r.status, "302");
  }],
  ["manager decompresses gzip once", async (p) => {
    const r = await viaManager(p, { url: `${upstream.url}/gzip` });
    expectEqual(p, "body", r.body, "hello gzip");
  }],
  ["manager wraps fetch failures", async (p) => {
    const r = await viaManager(p, { url: "http://127.0.0.1:1/" });
    if (!/^exception ConnectionFailure/.test(r.text)) p.push(r.text);
  }],
  ["manager wraps body-read failures", async (p) => {
    const r = await viaManager(p, { url: `${upstream.url}/broken-body` });
    if (!/^exception ConnectionFailure.*while reading the response body/s.test(r.text)) p.push(r.text);
  }],
];

// --- D1 against the local database of test/wrangler.toml (workerd only:
// Node has no D1) ----------------------------------------------------------

async function viaD1(path) {
  const res = await send(path);
  return { status: res.status, text: await res.text() };
}

const d1Checks = [
  ["d1 values round-trip", async (p) => {
    const r = await viaD1("/d1/roundtrip");
    expectEqual(p, "status", r.status, 200);
    expectEqual(p, "body", r.text,
      "i,j,r,s,b,n\nint:9007199254740991 int:-9007199254740991 real:1.5 text:héllo blob:00ff10 null");
  }],
  ["d1 rejects integers beyond 2^53", async (p) => {
    const r = await viaD1("/d1/too-big");
    expectEqual(p, "status", r.status, 500);
    if (!r.text.includes("outside the range")) p.push(r.text);
  }],
  ["d1 execute reports changes and the row id", async (p) => {
    expectEqual(p, "body", (await viaD1("/d1/run")).text, "changes=1 lastRowId=Just 1");
  }],
  ["d1 batch runs every statement", async (p) => {
    expectEqual(p, "body", (await viaD1("/d1/batch")).text, "1,1");
  }],
  ["d1 batch is atomic", async (p) => {
    expectEqual(p, "body", (await viaD1("/d1/batch-atomic")).text, "batch=failed count=int:0");
  }],
  ["d1 errors are D1Exception", async (p) => {
    const r = await viaD1("/d1/syntax");
    expectEqual(p, "status", r.status, 500);
    if (!/d1: .*syntax error/s.test(r.text)) p.push(r.text);
  }],
  ["d1 on a missing binding", async (p) => {
    const r = await viaD1("/d1/missing");
    expectEqual(p, "status", r.status, 500);
    if (!r.text.includes("env: NOPE is not set")) p.push(r.text);
  }],
  ["d1 error text appears once", async (p) => {
    const r = await viaD1("/d1/syntax");
    expectEqual(p, "status", r.status, 500);
    expectEqual(p, "message line", r.text.split("\n")[1],
      'd1: D1_ERROR: near "SELEC": syntax error at offset 0: SQLITE_ERROR');
  }],
  ["d1 on a binding that is not D1", async (p) => {
    const r = await viaD1("/d1/not-d1");
    expectEqual(p, "status", r.status, 500);
    if (!r.text.includes("d1: binding GREETING is not a D1 database")) p.push(r.text);
  }],
  ["d1 empty result keeps the column names", async (p) => {
    const r = await viaD1("/d1/empty");
    expectEqual(p, "status", r.status, 200);
    expectEqual(p, "body", r.text, "i\n");
  }],
  ["d1 REAL 1.0 reads back as an integer", async (p) => {
    expectEqual(p, "body", (await viaD1("/d1/real-one")).text, "r\nint:1");
  }],
  ["d1 rejects reading integers beyond 2^53", async (p) => {
    const r = await viaD1("/d1/read-overflow");
    expectEqual(p, "status", r.status, 500);
    if (!/d1: .*outside the exactly representable range/s.test(r.text)) p.push(r.text);
  }],
  ["d1 empty batch", async (p) => {
    const r = await viaD1("/d1/empty-batch");
    expectEqual(p, "status", r.status, 200);
    expectEqual(p, "body", r.text, "");
  }],
  ["d1 text round-trip (emoji, NUL)", async (p) => {
    const r = await viaD1("/d1/text");
    expectEqual(p, "status", r.status, 200);
    expectEqual(p, "body", r.text, "s\ntext:😀 héllo\ntext:a\u0000b");
  }],
  ["d1 empty and 64 KiB BLOBs round-trip", async (p) => {
    const r = await viaD1("/d1/blobs");
    expectEqual(p, "status", r.status, 200);
    expectEqual(p, "body", r.text, "blob 0 True\nblob 65536 True");
  }],
  ["d1 several rows in order", async (p) => {
    expectEqual(p, "body", (await viaD1("/d1/rows")).text, "k,v\nint:1 text:a\nint:2 text:b\nint:3 text:c");
  }],
  ["d1 wrong number of bindings is D1Exception", async (p) => {
    const r = await viaD1("/d1/bind-count");
    expectEqual(p, "status", r.status, 500);
    if (!/d1: .*Wrong number of parameter bindings/s.test(r.text)) p.push(r.text);
  }],
  // Each route below inserts its own id beyond 2^53 first, so none relies on
  // the connection state an earlier check left behind.
  ["d1 execute reports a row id beyond 2^53 as Nothing", async (p) => {
    const r = await viaD1("/d1/rowid-range/execute");
    expectEqual(p, "status", r.status, 200);
    expectEqual(p, "body", r.text, "lastRowId=Nothing");
  }],
  ["d1 batch reports a row id beyond 2^53 as Nothing", async (p) => {
    const r = await viaD1("/d1/rowid-range/batch");
    expectEqual(p, "status", r.status, 200);
    expectEqual(p, "body", r.text, "lastRowId=Nothing");
  }],
  ["d1 statements after a row id beyond 2^53 still run", async (p) => {
    const r = await viaD1("/d1/rowid-sticky");
    expectEqual(p, "status", r.status, 200);
    expectEqual(p, "body", r.text, "changes=1 lastRowId=Nothing");
    const run = await viaD1("/d1/run");
    expectEqual(p, "run status", run.status, 200);
    expectEqual(p, "run body", run.text, "changes=1 lastRowId=Just 1");
  }],
  ["d1 rejects non-finite reals", async (p) => {
    for (const [which, name] of [["nan", "NaN"], ["inf", "Infinity"]]) {
      const r = await viaD1(`/d1/nonfinite/${which}`);
      expectEqual(p, `${which} status`, r.status, 500);
      if (!r.text.includes(`d1: real ${name} is not finite`)) p.push(`${which}: ${r.text}`);
    }
  }],
];

// --- run --------------------------------------------------------------------

let failures = 0;
function report(name, problems) {
  if (problems.length === 0) {
    console.log(`ok   ${name}`);
  } else {
    failures += 1;
    console.log(`FAIL ${name}\n     ${problems.join("\n     ")}`);
  }
}

try {
  await Promise.all([workers.waitReady(), yesod.waitReady(), vendor.waitReady()]);
  console.log(`wrangler dev ready at ${workers.base}, ${yesod.base} and ${vendor.base}, upstream ${upstream.url}\n`);
  for (const c of cases) report(c.name, await check(send, c));
  for (const [name, run] of upstreamChecks) {
    const problems = [];
    try {
      await run(problems);
    } catch (e) {
      problems.push(`threw ${e?.stack ?? e}`);
    }
    report(name, problems);
  }
  for (const [name, run] of sessionChecks) {
    const problems = [];
    try {
      await run(problems);
    } catch (e) {
      problems.push(`threw ${e?.stack ?? e}`);
    }
    report(name, problems);
  }
  for (const [name, run] of staticChecks) {
    const problems = [];
    try {
      await run(problems);
    } catch (e) {
      problems.push(`threw ${e?.stack ?? e}`);
    }
    report(name, problems);
  }
  for (const [name, run] of persistChecks) {
    const problems = [];
    try {
      await run(problems);
    } catch (e) {
      problems.push(`threw ${e?.stack ?? e}`);
    }
    report(name, problems);
  }
  for (const [name, run] of vendorChecks) {
    const problems = [];
    try {
      await run(problems);
    } catch (e) {
      problems.push(`threw ${e?.stack ?? e}`);
    }
    report(name, problems);
  }
  for (const [name, run] of managerChecks) {
    const problems = [];
    try {
      await run(problems);
    } catch (e) {
      problems.push(`threw ${e?.stack ?? e}`);
    }
    report(name, problems);
  }
  for (const [name, run] of d1Checks) {
    const problems = [];
    try {
      await run(problems);
    } catch (e) {
      problems.push(`threw ${e?.stack ?? e}`);
    }
    report(name, problems);
  }
  if (/uncaught/i.test(workers.log + yesod.log + vendor.log)) {
    failures += 1;
    console.log("FAIL wrangler log has an uncaught exception");
  }
} catch (e) {
  failures += 1;
  console.log(`FAIL ${e.message}`);
}

if (failures > 0 || process.env.SHOW_WRANGLER_LOG) {
  console.log(`\n--- wrangler log (test-worker) ---\n${workers.log}--- wrangler log (test-yesod) ---\n${yesod.log}--- wrangler log (test-vendor) ---\n${vendor.log}--- end ---`);
}
await cleanup();
console.log(failures === 0 ? "\nall cases ok" : `\n${failures} case(s) failed`);
process.exit(failures === 0 ? 0 : 1);
