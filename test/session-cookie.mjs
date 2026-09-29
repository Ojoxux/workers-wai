// An independent implementation of the session cookie format
// (docs/specs/2026-09-30-yesod-session-design.md §2), used to read the
// cookies the Haskell backend writes and to forge ones it must accept or
// reject.

const enc = new TextEncoder();
const dec = new TextDecoder("utf-8", { fatal: true });
export const COOKIE = "_SESSION";
/** Additional authenticated data: cookie name ‖ format version. */
export function aadFor(name = COOKIE, version = 1) {
  return new Uint8Array([...enc.encode(name), version]);
}
const AAD = aadFor();

/** The 8-byte big-endian expiry that starts every plaintext. */
export function u64(n) {
  const b = new Uint8Array(8);
  new DataView(b.buffer).setBigUint64(0, BigInt(n));
  return b;
}

export async function sessionKey(secret) {
  const base = await crypto.subtle.importKey("raw", enc.encode(secret), "HKDF", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: enc.encode("yesod-cloudflare"), info: enc.encode("yesod-cloudflare session v1") },
    base,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

export function u32(n) {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, n);
  return b;
}

export function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

/** entries: { key: string -> value: string (UTF-8) } */
export function encodePayload(expires, entries) {
  const head = new Uint8Array(8);
  new DataView(head.buffer).setBigUint64(0, BigInt(expires));
  const items = Object.entries(entries).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  const body = items.flatMap(([k, v]) => {
    const kb = enc.encode(k);
    const vb = enc.encode(v);
    return [u32(kb.length), kb, u32(vb.length), vb];
  });
  return concat(head, u32(items.length), ...body);
}

export function decodePayload(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let off = 0;
  const need = (n) => {
    if (off + n > bytes.length) throw new Error("truncated");
  };
  need(8);
  const expires = Number(view.getBigUint64(0));
  off = 8;
  need(4);
  const count = view.getUint32(off);
  off += 4;
  const entries = {};
  for (let i = 0; i < count; i++) {
    need(4);
    const kl = view.getUint32(off);
    off += 4;
    need(kl);
    const k = dec.decode(bytes.subarray(off, off + kl));
    off += kl;
    need(4);
    const vl = view.getUint32(off);
    off += 4;
    need(vl);
    entries[k] = dec.decode(bytes.subarray(off, off + vl));
    off += vl;
  }
  if (off !== bytes.length) throw new Error("trailing bytes");
  return { expires, entries };
}

/**
 * Encrypt arbitrary plaintext bytes into a cookie value. The framing
 * (version byte, random 12-byte IV, AAD) defaults to the real format; the
 * options exist to forge cookies the backend must reject.
 */
export async function sealRaw(key, plaintext, { version = 1, aad = AAD } = {}) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: aad }, key, plaintext));
  return Buffer.from(concat(new Uint8Array([version]), iv, ct)).toString("base64url");
}

export async function seal(key, expires, entries) {
  return sealRaw(key, encodePayload(expires, entries));
}

/** The decoded session, or null if this key cannot open the cookie. */
export async function open(key, value) {
  const raw = new Uint8Array(Buffer.from(value, "base64url"));
  if (raw.length < 29 || raw[0] !== 1) return null;
  try {
    const pt = new Uint8Array(
      await crypto.subtle.decrypt({ name: "AES-GCM", iv: raw.subarray(1, 13), additionalData: AAD }, key, raw.subarray(13)),
    );
    return decodePayload(pt);
  } catch {
    return null;
  }
}

/** The _SESSION Set-Cookie line of a response, or undefined. */
export function sessionSetCookie(res) {
  return res.headers.getSetCookie().find((c) => c.startsWith(`${COOKIE}=`));
}

export function cookieValue(setCookieLine) {
  return setCookieLine.slice(COOKIE.length + 1).split(";")[0];
}
