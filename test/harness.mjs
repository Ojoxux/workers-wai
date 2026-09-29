// Shared helpers for test/*.test.mjs.
//
// Workers are booted through worker/src/runtime.mjs exactly as in production,
// from the wasm and JSFFI glue that scripts/test.sh stages in .test-build/.

import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { makeWorker } from "../worker/src/runtime.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

export const BASE = "http://example.test";

export async function loadWasm(target) {
  const dir = join(root, ".test-build", target);
  const wasmModule = await WebAssembly.compile(readFileSync(join(dir, "app.wasm")));
  const jsffi = (await import(pathToFileURL(join(dir, "ghc_wasm_jsffi.js")).href)).default;
  return { wasmModule, jsffi };
}

export async function loadWorker(target, options) {
  const { wasmModule, jsffi } = await loadWasm(target);
  return makeWorker(wasmModule, jsffi, options);
}

/** A stand-in ExecutionContext that records what waitUntil was given. */
export function fakeCtx() {
  const pending = [];
  return { ctx: { waitUntil: (p) => pending.push(p) }, pending };
}

/**
 * A local HTTP server for outbound fetch tests.
 *   /echo        -> 200 JSON { method, xtest, body }, header x-upstream: yes
 *   /status/:n   -> status n, empty body
 *   /beacon      -> 204
 *   /hold        -> does not respond until the returned `release()` is called,
 *                   then 204. Lets a test observe a request as still pending.
 *   /cookies     -> 200 with two Set-Cookie headers, x=1 and y=2.
 * Every request is recorded in `hits`.
 */
export function startUpstream() {
  const hits = [];
  const holds = [];
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = Buffer.concat(chunks).toString("utf8");
    hits.push({ method: req.method, url: req.url, body });

    if (req.url === "/echo") {
      res.writeHead(200, { "content-type": "application/json", "x-upstream": "yes" });
      res.end(JSON.stringify({ method: req.method, xtest: req.headers["x-test"] ?? null, body }));
      return;
    }
    const m = req.url.match(/^\/status\/(\d+)$/);
    if (m) {
      res.writeHead(Number(m[1]));
      res.end();
      return;
    }
    if (req.url === "/hold") {
      holds.push(res);
      return;
    }
    if (req.url === "/cookies") {
      res.setHeader("set-cookie", ["x=1", "y=2"]);
      res.writeHead(200);
      res.end();
      return;
    }
    res.writeHead(req.url === "/beacon" ? 204 : 404);
    res.end();
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      resolve({
        url: `http://127.0.0.1:${port}`,
        hits,
        close: () => new Promise((r) => server.close(r)),
        release: () => {
          for (const res of holds.splice(0)) {
            res.writeHead(204);
            res.end();
          }
        },
      });
    });
  });
}
