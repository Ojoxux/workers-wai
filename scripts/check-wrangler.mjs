// Run test-worker under `wrangler dev` (workerd) and check it over HTTP:
// the shared table in test/cases.mjs, plus workerd-only checks that need an
// upstream server (outbound fetch, Set-Cookie passthrough, waitUntil).
//
//   node scripts/check-wrangler.mjs
//   SHOW_WRANGLER_LOG=1 node scripts/check-wrangler.mjs   # print the log even on success
//
// Requires a build of test-worker in .test-build/ first: scripts/test.sh, or
// scripts/build.sh test-worker .test-build/test-worker.
//
// The script starts the upstream from test/harness.mjs and wrangler itself,
// and always stops both on exit, failure or Ctrl-C.

import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { cases, check } from "../test/cases.mjs";
import { startUpstream } from "../test/harness.mjs";

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
const port = await freePort();
const base = `http://127.0.0.1:${port}`;

let log = "";
const wrangler = spawn(
  join(root, "worker/node_modules/.bin/wrangler"),
  ["dev", "-c", "test/wrangler.toml", "--port", String(port), "--ip", "127.0.0.1",
   "--var", `UPSTREAM:${upstream.url}`],
  {
    cwd: root,
    detached: true, // own process group, so workerd dies with it
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, WRANGLER_SEND_METRICS: "false", CI: "1" },
  },
);
wrangler.stdout.on("data", (d) => (log += d));
wrangler.stderr.on("data", (d) => (log += d));
let wranglerExited = false;
wrangler.on("exit", () => (wranglerExited = true));

let cleanedUp = false;
async function cleanup() {
  if (cleanedUp) return;
  cleanedUp = true;
  upstream.release();
  if (!wranglerExited) {
    try { process.kill(-wrangler.pid, "SIGTERM"); } catch {}
    for (let i = 0; i < 50 && !wranglerExited; i++) await sleep(100);
    try { process.kill(-wrangler.pid, "SIGKILL"); } catch {}
  }
  await upstream.close();
}
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, async () => {
    await cleanup();
    process.exit(130);
  });
}

async function waitReady() {
  const deadline = Date.now() + READY_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (wranglerExited) throw new Error("wrangler exited before becoming ready");
    try {
      const res = await fetch(`${base}/hello`);
      if (res.status === 200) return;
    } catch {}
    await sleep(250);
  }
  throw new Error(`wrangler not ready after ${READY_TIMEOUT_MS / 1000}s`);
}

// --- upstream-dependent checks (workerd only; Node covers them in
// fetch/context/headers.test.mjs with the same expectations) ----------------

const send = (path, init) => fetch(`${base}${path}`, init);

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
    const logBefore = log.length;
    upstream.release();
    await sleep(1000);
    const after = log.slice(logBefore);
    if (/uncaught|exception|error|waitUntil/i.test(after)) p.push(`wrangler logged after release:\n${after}`);
  }],
  // Shows that the log check above would see a waitUntil failure.
  ["waitUntil failure is logged", async (p) => {
    const res = await send("/wait/fail");
    expectEqual(p, "status", res.status, 200);
    const deadline = Date.now() + 5000;
    while (!log.includes("waitUntil: user error (boom)") && Date.now() < deadline) await sleep(50);
    if (!log.includes("waitUntil: user error (boom)")) p.push("wrangler log has no \"waitUntil: user error (boom)\"");
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
  await waitReady();
  console.log(`wrangler dev ready at ${base}, upstream ${upstream.url}\n`);
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
  if (/uncaught/i.test(log)) {
    failures += 1;
    console.log("FAIL wrangler log has an uncaught exception");
  }
} catch (e) {
  failures += 1;
  console.log(`FAIL ${e.message}`);
}

if (failures > 0 || process.env.SHOW_WRANGLER_LOG) console.log(`\n--- wrangler log ---\n${log}--- end wrangler log ---`);
await cleanup();
console.log(failures === 0 ? "\nall cases ok" : `\n${failures} case(s) failed`);
process.exit(failures === 0 ? 0 : 1);
