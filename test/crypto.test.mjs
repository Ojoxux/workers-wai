// Cloudflare.Workers.Crypto against the platform's own WebCrypto: the same
// inputs must give byte-identical output.

import { test } from "node:test";
import assert from "node:assert/strict";
import { BASE, fakeCtx, loadWorker } from "./harness.mjs";

const worker = await loadWorker("test-worker", { exposeErrors: true });
const enc = new TextEncoder();
const hex = (bytes) => Buffer.from(bytes).toString("hex");

async function get(path) {
  const res = await worker.fetch(new Request(`${BASE}${path}`), {}, fakeCtx().ctx);
  return { status: res.status, text: await res.text() };
}

async function referenceKey(ikm, salt, info) {
  const base = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt, info },
    base,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

const input = {
  ikm: enc.encode("a secret that is at least thirty-two bytes long"),
  salt: enc.encode("salt"),
  info: enc.encode("info"),
  iv: new Uint8Array(12).map((_, i) => i + 1),
  aad: enc.encode("aad"),
  pt: enc.encode("hello, 世界"),
};
const query = (o) => new URLSearchParams(Object.entries(o).map(([k, v]) => [k, hex(v)])).toString();

test("seal matches WebCrypto HKDF + AES-GCM byte for byte", async () => {
  const key = await referenceKey(input.ikm, input.salt, input.info);
  const expected = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: input.iv, additionalData: input.aad }, key, input.pt),
  );
  const res = await get(`/crypto/seal?${query(input)}`);
  assert.equal(res.status, 200);
  assert.equal(res.text, hex(expected));
});

test("open reverses seal", async () => {
  const sealed = (await get(`/crypto/seal?${query(input)}`)).text;
  const { pt, ...rest } = input;
  const res = await get(`/crypto/open?${query(rest)}&ct=${sealed}`);
  assert.equal(res.text, hex(pt));
});

test("open returns Nothing for a tampered ciphertext, a wrong key or a wrong AAD", async () => {
  const sealed = (await get(`/crypto/seal?${query(input)}`)).text;
  const { pt, ...rest } = input;
  const flipped = sealed.slice(0, -2) + (sealed.slice(-2) === "00" ? "01" : "00");
  assert.equal((await get(`/crypto/open?${query(rest)}&ct=${flipped}`)).text, "Nothing");
  assert.equal(
    (await get(`/crypto/open?${query({ ...rest, ikm: enc.encode("a different secret of at least 32 bytes!!") })}&ct=${sealed}`)).text,
    "Nothing",
  );
  assert.equal((await get(`/crypto/open?${query({ ...rest, aad: enc.encode("other") })}&ct=${sealed}`)).text, "Nothing");
});

test("open returns Nothing for a ciphertext shorter than the tag", async () => {
  const sealed = (await get(`/crypto/seal?${query(input)}`)).text;
  const { pt, ...rest } = input;
  assert.equal((await get(`/crypto/open?${query(rest)}&ct=${sealed.slice(0, 20)}`)).text, "Nothing");
});

test("an empty IV is a caller error, for seal and for open", async () => {
  const sealed = (await get(`/crypto/seal?${query(input)}`)).text;
  const { pt, ...rest } = input;
  const empty = new Uint8Array(0);
  const seal = await get(`/crypto/seal?${query({ ...input, iv: empty })}`);
  assert.equal(seal.status, 500);
  assert.match(seal.text, /empty IV/);
  const open = await get(`/crypto/open?${query({ ...rest, iv: empty })}&ct=${sealed}`);
  assert.equal(open.status, 500);
  assert.match(open.text, /empty IV/);
});

// "<len> <any byte non-zero> <any of the last 64 bytes non-zero>": the tail
// check catches a chunk that was never filled.
test("randomBytes fills every chunk across the 65536-byte limit", async () => {
  assert.equal((await get("/crypto/random/100000")).text, "100000 True True");
  assert.equal((await get("/crypto/random/65536")).text, "65536 True True");
  assert.equal((await get("/crypto/random/65537")).text, "65537 True True");
  assert.equal((await get("/crypto/random/0")).text, "0 False False");
});

test("two random draws differ", async () => {
  const a = await get("/crypto/random-hex/16");
  const b = await get("/crypto/random-hex/16");
  assert.equal(a.text.length, 32);
  assert.notEqual(a.text, b.text);
});
