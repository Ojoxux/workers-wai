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

**4. Use the Workers session backend.** The `clientsession` shim has no
cryptography, so `defaultClientSessionBackend` cannot work. `yesod-cloudflare`
provides a backend on WebCrypto AES-256-GCM instead:

```haskell
import Yesod.Cloudflare.Session

main = runCloudflareWith $ \env -> do
  key <- Env.var env "SESSION_KEY"            -- a Secret, at least 32 bytes
  backend <- cloudflareSessionBackend (SessionKeys key []) 120
  toWaiAppPlain (App backend)

instance Yesod App where
  makeSessionBackend = pure . Just . appSessionBackend
```

It behaves like `clientSessionBackend`: an encrypted `_SESSION` cookie
(`HttpOnly; Path=/; Expires`), an idle timeout in minutes that restarts on every
request, and an empty session for any cookie it cannot read. `sslOnlySessions`,
`laxSameSiteSessions` and friends compose with it as usual, and so do
`defaultCsrfMiddleware` and yesod-auth, which only need a working session.

Differences from `clientSessionBackend`:

- The current time is read per request instead of from a background cache
  thread.
- A session whose encoded cookie exceeds 4,000 bytes throws `SessionTooLarge`
  instead of producing a cookie the browser silently drops.
- A timeout below 1 minute is rejected when the backend is built.

If a request carries several `_SESSION` cookies (say one per Path or Domain),
the session is used only when exactly one of them opens, that is, authenticates
under some key and has not expired; otherwise it is empty. yesod-core's
`clientSessionBackend` applies the same rule.

**Keys.** A key is a random secret of at least 32 bytes, for example the output
of `openssl rand -base64 32`, stored as a Secret. It is not a passphrase: keys go
through HKDF, which is not a password hash and does nothing to slow guessing.
Shorter keys are rejected with `SessionKeyTooShort`. IVs are random 96-bit
values, so rotate a key well before it has written 2^32 sessions; that only
matters at very high traffic.

**Rotating the key.** Put the new Secret in `currentKey` and the previous one in
`oldKeys`. Sessions under the old key are still read and are rewritten under the
new one on their next request; drop the old key once the idle timeout has
passed.

The cookie format is documented in `Yesod.Cloudflare.Session.Codec` and
reimplemented, for the tests, in `test/session-cookie.mjs`.

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

Sessions, CSRF and anything built on them work with `Yesod.Cloudflare.Session`.
See [wai-support.md](wai-support.md) for what is still unsupported. File uploads
and the gzip middleware link but rest on shimmed code paths and are untested.
