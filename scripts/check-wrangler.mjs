// Run test/cases.mjs against a running `wrangler dev` of test/wrangler.toml.
//
//   worker/node_modules/.bin/wrangler dev -c test/wrangler.toml --port 8788
//   node scripts/check-wrangler.mjs [base-url]      # default http://localhost:8788

import { cases, check } from "../test/cases.mjs";

const base = process.argv[2] ?? "http://localhost:8788";
const send = (path, init) => fetch(`${base}${path}`, init);

let failures = 0;
for (const c of cases) {
  const problems = await check(send, c);
  if (problems.length === 0) {
    console.log(`ok   ${c.name}`);
  } else {
    failures += 1;
    console.log(`FAIL ${c.name}\n     ${problems.join("\n     ")}`);
  }
}

console.log(failures === 0 ? "\nall cases ok" : `\n${failures} case(s) failed`);
process.exit(failures === 0 ? 0 : 1);
