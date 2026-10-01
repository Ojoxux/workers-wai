// Run test-worker under `wrangler dev` (workerd) and check it over HTTP:
// the shared table in test/cases.mjs, plus workerd-only checks that need an
// upstream server (outbound fetch, Set-Cookie passthrough, waitUntil). It also
// starts test/yesod-wrangler.toml (test-yesod) and checks sessions and CSRF, and
// test/vendor-wrangler.toml (test-vendor) and checks the vendored crypto stack.
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
  for (const [name, run] of vendorChecks) {
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
