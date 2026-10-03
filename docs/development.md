# Development

## Inspecting the wasm module

```sh
node scripts/inspect-wasm.mjs worker/generated/app.wasm
```

Lists the module's imports grouped by import module, and its exports.

Two things are worth checking with it:

**The WASI import list.** `worker/src/wasi.mjs` implements exactly the
`wasi_snapshot_preview1` functions this reports — no more, no fewer. The set
really does move: `demo-wai` needs 20, `demo-yesod` needs 21. Re-run this after
changing the GHC version or the dependency set.

**That the exports are there.** `setEnv`, `workerMain` and `handleRequest`
should all appear. GHC emits them automatically for `foreign export
javascript`, but a typo in the export name produces a module that instantiates
fine and then fails with `instance.exports.workerMain is not a function`.

## Tests

```sh
scripts/test.sh
```

Builds `test-worker`, `test-yesod`, `test-vendor`, `demo-wai` and `demo-yesod` into
`.test-build/`, then runs `test/*.test.mjs` with Node's test runner. Each test boots a module
through `worker/src/runtime.mjs` — the same code path as production — with a
fake `ExecutionContext` and, for outbound fetch, a local HTTP server.

After the first build, `node --test --test-force-exit --test-timeout=30000
"test/*.test.mjs"` reruns the tests alone — plain `node --test` never exits
once a test has loaded `demo-yesod`, whose background threads keep a JS timer
alive (see [constraints.md](constraints.md)).

`test-vendor` is the vendored crypto stack with yesod-auth inside, about 9.8 MiB.
Its checks are listed in `haskell/vendor/README.md`. It also serves `/http`, which
runs one http-client request through the fetch-backed Manager
(`haskell/http-client-cloudflare`, see [http-client.md](http-client.md));
`test/fetch-manager.test.mjs` drives that route against the local upstream.

Node is not workerd. To check `test-worker`, `test-yesod` and `test-vendor` against the real
runtime:

```sh
node scripts/check-wrangler.mjs
```

It needs builds of `test-worker`, `test-yesod` and `test-vendor` in `.test-build/` (`scripts/test.sh` makes
them). The script starts the upstream server from `test/harness.mjs`, runs
`wrangler dev -c test/wrangler.toml` on a free port with `UPSTREAM` pointing at
it, waits for `/hello`, and then runs the shared cases in `test/cases.mjs` plus
workerd-only checks that need the upstream: outbound fetch, Set-Cookie
passthrough, and `waitUntil` work continuing after the response. wrangler and
the upstream are stopped on exit, failure or Ctrl-C. `SHOW_WRANGLER_LOG=1`
prints wrangler's log even when everything passes (it is always printed on
failure).

The first instance also has a local D1 database (binding `DB` in `test/wrangler.toml`)
and runs 21 D1 checks against it (see [d1.md](d1.md)). D1 runs only under
`wrangler dev`: Node has no D1, so these checks are not in `test/cases.mjs`.

It also starts a second instance, `wrangler dev -c test/yesod-wrangler.toml`,
and runs two session and CSRF checks against it, two checks that its
yesod-static URLs are served by Workers Static Assets (`[assets]` in
`test/yesod-wrangler.toml`, see [yesod.md](yesod.md#static-files)), then 8 persistent checks
against its own local D1 (binding `DB` in `test/yesod-wrangler.toml`):
migration, CRUD, ids of concurrent inserts, field type round trips, a unique
constraint, bulk writes past 100 parameters, `createD1Pool` with
`runSqlPool`, and a migration that rebuilds a table (see
[persistent-d1.md](persistent-d1.md)). A third instance,
`wrangler dev -c test/vendor-wrangler.toml` (`test-vendor`), runs 10 checks: the
vendored crypto and CBOR vectors, randomness through `random_get`, the real
clientsession round trip, the yesod-auth login page, and 6 manager checks for the
fetch-backed http-client Manager (GET, form POST, redirects left to http-client,
gzip decoded once, fetch failures and body-read failures wrapped). Each instance gets its own free
inspector port and its own `--persist-to` state directory under
`.wrangler/state/`, because two instances otherwise collide (see
[constraints.md](constraints.md)).

## The build script

```sh
scripts/build.sh [target] [out-dir]   # defaults: demo-wai, worker/generated
```

It does three things:

1. `wasm32-wasi-cabal build exe:$TARGET`
2. copies the linked module to `worker/generated/app.wasm`
3. runs `$(wasm32-wasi-ghc --print-libdir)/post-link.mjs` to emit
   `worker/generated/ghc_wasm_jsffi.js`

Step 3 is not optional. The post-linker parses the `ghc_wasm_jsffi` custom
section out of the wasm module and generates the JavaScript half of every
`foreign import javascript` declaration, so the glue must be regenerated whenever
the Haskell changes.

`worker/generated/` is gitignored; both demos share it, so switching between them
is just a rebuild.

## Diagnosing dependency failures

```sh
wasm32-wasi-cabal build exe:demo-yesod --keep-going   # all failures in one run
wasm32-wasi-cabal build exe:demo-yesod --dry-run      # who pulls in what
```

Failures cascade, so the first list of broken packages is usually much longer
than the list of genuinely broken ones. Check what is actually independent before
writing any shim — see [yesod.md](yesod.md) for how that played out here.

## Adding a shim

1. Create `haskell/shims/<name>/` with a `.cabal` file whose `version:` matches
   the Hackage release being shadowed, so bounds resolve.
2. Add it to `packages:` in `cabal.project`. Local packages shadow Hackage.
3. Derive the API surface by grepping the actual consumers, not by reading the
   upstream haddocks — the needed subset is usually tiny.
4. Make unimplementable operations raise a descriptive error naming the function
   and explaining why the platform cannot support it. Do not return plausible
   dummy values.
5. Document the faithfulness of the replacement in the `.cabal` description and
   in [shims.md](shims.md). Whether a shim is real or fictional is the single
   most important thing to record about it.

If the real package only needs a patch to build, vendor it instead of shimming
it: see `haskell/vendor/README.md`.
