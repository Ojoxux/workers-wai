import { test } from "node:test";
import assert from "node:assert/strict";
import { BASE, fakeCtx, loadWorker } from "./harness.mjs";
import {
  aadFor,
  concat,
  COOKIE,
  cookieValue,
  open,
  seal,
  sealRaw,
  sessionKey,
  sessionSetCookie,
  u32,
  u64,
} from "./session-cookie.mjs";

const CURRENT = "test-session-key-current-0123456789abcdef";
const OLD = "test-session-key-previous-0123456789abcdef";
const OTHER = "test-session-key-unrelated-0123456789abcdef";
const env = { SESSION_KEY: CURRENT, SESSION_KEY_OLD: OLD };

const worker = await loadWorker("test-yesod", { exposeErrors: true });
const now = () => Math.floor(Date.now() / 1000);

async function send(path, { cookie, method = "GET", headers = {} } = {}) {
  const h = new Headers(headers);
  if (cookie) h.set("cookie", cookie);
  const res = await worker.fetch(new Request(`${BASE}${path}`, { method, headers: h }), env, fakeCtx().ctx);
  return { res, status: res.status, text: await res.text() };
}

const withSession = (value) => `${COOKIE}=${value}`;

test("the session survives across requests only when the cookie is sent back", async () => {
  const first = await send("/count");
  assert.equal(first.text, "1");
  const value = cookieValue(sessionSetCookie(first.res));
  const second = await send("/count", { cookie: withSession(value) });
  assert.equal(second.text, "2");
  assert.equal((await send("/count")).text, "1");
});

test("the cookie is HttpOnly, Path=/ and expires about 120 minutes out", async () => {
  const { res } = await send("/count");
  const line = sessionSetCookie(res);
  assert.match(line, /HttpOnly/i);
  assert.match(line, /Path=\//);
  // cookie renders e.g. "Wed, 30-Sep-2026 12:00:00 GMT"; dashes to spaces for Date.parse
  const expires = Date.parse(line.match(/Expires=([^;]+)/i)[1].replace(/-/g, " ")) / 1000;
  assert.ok(Math.abs(expires - (now() + 120 * 60)) < 300, line);
});

test("the cookie follows the documented format under the current key", async () => {
  const { res } = await send("/count");
  const opened = await open(await sessionKey(CURRENT), cookieValue(sessionSetCookie(res)));
  assert.ok(opened);
  assert.equal(opened.entries.count, "1");
  assert.ok(Math.abs(opened.expires - (now() + 120 * 60)) < 300);
});

test("an expired cookie is an empty session", async () => {
  const value = await seal(await sessionKey(CURRENT), now() - 10, { count: "41" });
  assert.equal((await send("/count", { cookie: withSession(value) })).text, "1");
});

test("a cookie under the old key is read and rewritten under the current key", async () => {
  const value = await seal(await sessionKey(OLD), now() + 600, { count: "5" });
  const { res, text } = await send("/count", { cookie: withSession(value) });
  assert.equal(text, "6");
  const rewritten = cookieValue(sessionSetCookie(res));
  assert.equal((await open(await sessionKey(CURRENT), rewritten)).entries.count, "6");
  assert.equal(await open(await sessionKey(OLD), rewritten), null);
});

test("cookies under an unknown key, garbage and tampered cookies are empty sessions", async () => {
  const unknown = await seal(await sessionKey(OTHER), now() + 600, { count: "7" });
  assert.equal((await send("/count", { cookie: withSession(unknown) })).text, "1");
  assert.equal((await send("/count", { cookie: withSession("not-a-cookie") })).text, "1");
  const good = await seal(await sessionKey(CURRENT), now() + 600, { count: "9" });
  const raw = Buffer.from(good, "base64url");
  raw[raw.length - 1] ^= 1;
  assert.equal((await send("/count", { cookie: withSession(raw.toString("base64url")) })).text, "1");
});

test("authenticated but malformed payloads are empty sessions", async () => {
  const key = await sessionKey(CURRENT);
  const later = u64(now() + 600);
  const bytes = (s) => new TextEncoder().encode(s);
  const countEntry = concat(u32(5), bytes("count"), u32(2), bytes("41"));
  const cases = {
    // A key length that does not fit a 32-bit Int must not wrap around and
    // let the entry that follows be read.
    "klen 0xFFFFFFFF": concat(later, u32(2), u32(0xffffffff), u32(0), countEntry),
    "klen 0x80000000": concat(later, u32(2), u32(0x80000000), u32(0), countEntry),
    "huge count, no entries": concat(later, u32(0xffffffff)),
    "huge count, one entry": concat(later, u32(0xffffffff), countEntry),
    "trailing bytes": concat(later, u32(1), countEntry, new Uint8Array([0])),
    "invalid UTF-8 key": concat(later, u32(2), u32(1), new Uint8Array([0xff]), u32(0), countEntry),
  };
  for (const [name, plaintext] of Object.entries(cases)) {
    const value = await sealRaw(key, plaintext);
    assert.equal((await send("/count", { cookie: withSession(value) })).text, "1", name);
  }
});

test("a wrong version byte or a different AAD is an empty session", async () => {
  const key = await sessionKey(CURRENT);
  const plaintext = concat(u64(now() + 600), u32(1), u32(5), new TextEncoder().encode("count"), u32(2), new TextEncoder().encode("41"));
  // Sanity: the same plaintext under the real framing is read.
  assert.equal((await send("/count", { cookie: withSession(await sealRaw(key, plaintext)) })).text, "42");
  const forged = {
    "version 2, AAD for version 1": await sealRaw(key, plaintext, { version: 2 }),
    "version 2 throughout": await sealRaw(key, plaintext, { version: 2, aad: aadFor(COOKIE, 2) }),
    "AAD with version 2": await sealRaw(key, plaintext, { aad: aadFor(COOKIE, 2) }),
    "AAD for another cookie name": await sealRaw(key, plaintext, { aad: aadFor("OTHER", 1) }),
  };
  for (const [name, value] of Object.entries(forged)) {
    assert.equal((await send("/count", { cookie: withSession(value) })).text, "1", name);
  }
});

test("duplicate session cookies: only a single one that opens is used", async () => {
  const key = await sessionKey(CURRENT);
  const five = await seal(key, now() + 600, { count: "5" });
  const nine = await seal(key, now() + 600, { count: "9" });
  const expired = await seal(key, now() - 10, { count: "7" });
  assert.equal((await send("/count", { cookie: `${COOKIE}=junk; ${COOKIE}=${five}` })).text, "6");
  assert.equal((await send("/count", { cookie: `${COOKIE}=${five}; ${COOKIE}=junk` })).text, "6");
  assert.equal((await send("/count", { cookie: `${COOKIE}=${expired}; ${COOKIE}=${nine}` })).text, "10");
  assert.equal((await send("/count", { cookie: `${COOKIE}=${five}; ${COOKIE}=${nine}` })).text, "1");
});

test("CSRF: a POST without the token is rejected, with it accepted", async () => {
  const form = await send("/form");
  const token = form.text;
  assert.ok(token.length > 0);
  const cookie = withSession(cookieValue(sessionSetCookie(form.res)));
  assert.equal((await send("/form", { method: "POST", cookie })).status, 403);
  const accepted = await send("/form", { method: "POST", cookie, headers: { "X-XSRF-TOKEN": token } });
  assert.equal(accepted.status, 200);
  assert.equal(accepted.text, "ok");
});

test("a session too large for a cookie fails loudly", async () => {
  const logged = [];
  const original = console.error;
  console.error = (...a) => logged.push(a.join(" "));
  try {
    const { status, text } = await send("/large");
    assert.equal(status, 500);
    assert.match(text + logged.join("\n"), /session cookie too large|SessionTooLarge/);
  } finally {
    console.error = original;
  }
});

test("a key shorter than 32 bytes stops the worker from booting", async () => {
  const short = await loadWorker("test-yesod", { exposeErrors: true });
  const logged = [];
  const original = console.error;
  console.error = (...a) => logged.push(a.join(" "));
  try {
    const res = await short.fetch(new Request(`${BASE}/count`), { SESSION_KEY: "short" }, fakeCtx().ctx);
    assert.equal(res.status, 500);
    assert.match((await res.text()) + logged.join("\n"), /at least 32 bytes|SessionKeyTooShort/);
  } finally {
    console.error = original;
  }
});

test("a key in oldKeys shorter than 32 bytes stops the worker from booting", async () => {
  const short = await loadWorker("test-yesod", { exposeErrors: true });
  const logged = [];
  const original = console.error;
  console.error = (...a) => logged.push(a.join(" "));
  try {
    const res = await short.fetch(new Request(`${BASE}/count`), { SESSION_KEY: CURRENT, SESSION_KEY_OLD: "short" }, fakeCtx().ctx);
    assert.equal(res.status, 500);
    assert.match((await res.text()) + logged.join("\n"), /at least 32 bytes|SessionKeyTooShort/);
  } finally {
    console.error = original;
  }
});

test("a timeout under one minute stops the worker from booting", async () => {
  const zero = await loadWorker("test-yesod", { exposeErrors: true });
  const logged = [];
  const original = console.error;
  console.error = (...a) => logged.push(a.join(" "));
  try {
    const res = await zero.fetch(new Request(`${BASE}/count`), { ...env, SESSION_MINUTES: "0" }, fakeCtx().ctx);
    assert.equal(res.status, 500);
    assert.match((await res.text()) + logged.join("\n"), /timeout must be at least 1 minute/);
  } finally {
    console.error = original;
  }
});
