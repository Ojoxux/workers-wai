# Putting Yesod on top

The handler does not change at all between a bare WAI `Application` and Yesod —
that was the point of the exercise. What follows is what it took to get
`yesod-core` to *build* for `wasm32-wasi`.

## The application

Only the `foreign export` line distinguishes this from a `warp`-hosted Yesod app:

```haskell
foreign export javascript "workerMain" main :: IO ()

main :: IO ()
main = do
  app <- toWaiAppPlain App
  runCloudflare app
```

`toWaiAppPlain` rather than `toWaiApp`, because the latter installs the default
middleware stack including request logging, which is not what you want inside a
Worker.

## Steps

**1. Enable the right extensions.** The usual Yesod set, plus `ViewPatterns`,
which `parseRoutes` needs for dynamic route segments:

```haskell
{-# LANGUAGE TemplateHaskell, QuasiQuotes, TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses, OverloadedStrings, ViewPatterns #-}
```

Template Haskell works on GHC 9.12's wasm backend, so `mkYesod`, `parseRoutes`
and `whamlet` all run normally. This is the whole reason for pinning 9.12 rather
than taking `ghc-wasm-meta`'s 9.14 default.

**2. Find every broken dependency at once.**

```sh
wasm32-wasi-cabal build exe:demo-yesod --keep-going
```

Without `--keep-going`, cabal stops at the first failure and you discover the
list one slow build at a time. With it, they all surface in a single run. Six
packages failed initially: `basement`, `ram`, `entropy`, `recv`,
`streaming-commons` and `http-semantics`.

**3. Check which failures are actually independent.** They were not. `recv`,
`streaming-commons` and `http-semantics` all failed for the same reason — a
`network` stub too thin to satisfy them — and `basement` and `ram` were both
reachable only through `memory` → `crypton` → `clientsession`. Four shims and one
cabal flag covered all six. See [shims.md](shims.md).

Inspecting the install plan is the quickest way to see who pulls what:

```sh
wasm32-wasi-cabal build exe:demo-yesod --dry-run
```

That is how `crypton-x509` was traced back to `warp`'s `x509` flag rather than to
anything Yesod actually wanted.

**4. Disable sessions**, because the `clientsession` shim has no cryptography:

```haskell
instance Yesod App where
  makeSessionBackend _ = pure Nothing
```

**5. Re-check the WASI imports.** The Yesod build needs one more than the WAI
build:

```sh
node scripts/inspect-wasm.mjs worker/generated/app.wasm
```

`path_unlink_file` appeared, and had to be added to `worker/src/wasi.mjs`. The
shim reports unimplemented imports by name when called, so this would have
surfaced as a clear log line rather than a mysterious failure — but checking is
cheaper than debugging.

## What works

Routing, type-safe URLs, Hamlet templates, `defaultLayout`, and Yesod's own 404
and 405 responses. Verified under `wrangler dev`:

```console
$ curl http://localhost:8787/hello/world
<!DOCTYPE html>
<html><head><title>workers-wai</title></head><body><h1>Hello, world!</h1>
<p><a href="http://localhost:8787/">Back</a>
</p>
</body></html>

$ curl -o /dev/null -w '%{http_code}\n' http://localhost:8787/nope
404
```

Cold start 27 ms, warm requests 2–3 ms, `app.wasm` 4.1 MiB.

## What does not

Sessions, and anything downstream of them — see
[wai-support.md](wai-support.md) for the full list. File uploads and the gzip
middleware link but rest on shimmed code paths and are untested.

The obvious next step is a Workers-native session backend built on WebCrypto,
which would remove the only genuinely fictional shim.
