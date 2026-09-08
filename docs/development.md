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

**That the exports are there.** `waiMain` and `handleRequest` should both appear.
GHC emits them automatically for `foreign export javascript`, but a typo in the
export name produces a module that instantiates fine and then fails with
`instance.exports.waiMain is not a function`.

## Fast feedback loop

```sh
node scripts/smoke.mjs
```

Boots the same wasm module under Node, with the same WASI shim and the same
generated JSFFI glue, and drives it with synthetic `Request`s. Node exposes the
same `Request`, `Response` and `URL` globals as the Workers runtime, so the code
under test is identical — but it runs in about a second instead of starting
`wrangler`.

Use it for everything except the final check. It covers the root route, path and
query parsing, header conversion, a POST with a body, and `responseStream`.

The one thing it cannot tell you is how workerd itself behaves, so confirm with
`wrangler dev` before believing a result.

## The build script

```sh
scripts/build.sh [target]     # target defaults to demo-wai
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
