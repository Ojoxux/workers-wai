// HTTP-level cases for test-worker that need no upstream server and no fake
// ExecutionContext, so the same table runs under Node (cases.test.mjs) and
// against `wrangler dev` (scripts/check-wrangler.mjs).

export const env = { GREETING: "hello from vars" };

export const cases = [
  { name: "hello", path: "/hello", status: 200, body: "hello" },
  { name: "env var", path: "/env/var/GREETING", status: 200, body: "hello from vars" },
  { name: "env as environ", path: "/env/environ/GREETING", status: 200, body: 'Just "hello from vars"' },
  { name: "missing var", path: "/env/var/NOPE", status: 500, includes: "is not set" },
  { name: "null-body status", path: "/status/204", status: 204, body: "" },
  { name: "body echo", method: "POST", path: "/body/echo", requestBody: "hello body", status: 200, body: "hello body" },
  { name: "body read twice", method: "POST", path: "/body/twice", requestBody: "x", status: 500, includes: "body already used" },
  { name: "bad url", path: "/fetch/badurl", status: 500, includes: "TypeError" },
  { name: "invalid status", path: "/status/99", status: 500, includes: "RangeError" },
  { name: "crypto self-test", path: "/crypto/selftest", status: 200, body: "ok" },
  { name: "crypto random", path: "/crypto/random/100000", status: 200, body: "100000 True True" },
];

/** Returns a list of problems; empty means the case passed. */
export async function check(send, c) {
  const res = await send(c.path, { method: c.method ?? "GET", body: c.requestBody });
  const text = await res.text();
  const problems = [];
  if (res.status !== c.status) problems.push(`status ${res.status}, expected ${c.status}`);
  if (c.body !== undefined && text !== c.body) problems.push(`body ${JSON.stringify(text)}, expected ${JSON.stringify(c.body)}`);
  if (c.includes !== undefined && !text.includes(c.includes)) problems.push(`body does not include ${JSON.stringify(c.includes)}: ${JSON.stringify(text)}`);
  return problems;
}
