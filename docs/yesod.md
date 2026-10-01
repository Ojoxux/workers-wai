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
cabal flag covered all six at the time; `memory` and `clientsession` have since
been replaced by the real packages, so two shims remain. See [shims.md](shims.md).

Inspecting the install plan is the quickest way to see who pulls what:

```sh
wasm32-wasi-cabal build exe:demo-yesod --dry-run
```

That is how `crypton-x509` was traced back to `warp`'s `x509` flag rather than to
anything Yesod actually wanted.

**4. Choose a session backend.** The real `clientsession` now builds, over the
vendored `crypton`, so yesod-core's `envClientSessionBackend` works. The key
comes from the environment, which `makeWorker` fills from the Worker's `env`
object: with `envClientSessionBackend 120 "SESSION_KEY"`, `SESSION_KEY` holds
the base64 of 96 bytes. `test-yesod` uses this when
`SESSION_BACKEND=clientsession`.

`defaultClientSessionBackend` does not work on Workers: it reads and, when
missing, creates `config/client_session_key.aes`, and there is no filesystem
(`path_open` returns `EBADF`), so building the backend throws.

Always set a valid key, for example with
`openssl rand -base64 96 | tr -d '\n'`. If `SESSION_KEY` is missing or is not
the base64 of 96 bytes, clientsession's `getKeyEnv` does not fail: it generates a
random key for that isolate, sets the variable, and prints
`SESSION_KEY=<base64 key>` with `putStrLn`. On Workers that is `console.log`, so
the key lands in Workers logs and `wrangler tail`, and every cold start or new
isolate gets a different key, which breaks all existing sessions.

`Yesod.Cloudflare.Session` is still the recommendation: it supports key
rotation, uses WebCrypto AES-256-GCM, which the Workers runtime provides
natively, and fails loudly on a bad key. It looks like this:

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

**One key per app.** The HKDF salt and info are fixed, so two apps sharing a key
accept each other's cookies. Give every app its own.

**Production.** For login state, wrap the backend so the cookie is `Secure` and
`SameSite=Lax`. Both wrappers take and return `IO (Maybe SessionBackend)`:

```haskell
instance Yesod App where
  makeSessionBackend =
    laxSameSiteSessions . sslOnlySessions . pure . Just . appSessionBackend
```

**Revocation.** Logging out or `clearSession` only empties the session the
browser sends next; it does not invalidate a cookie someone has already copied,
and because the timeout slides, a thief who keeps using the cookie keeps it
alive. Rotating the key, and later dropping the old one from `oldKeys`, is the
only global revocation.

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

## yesod-auth

`yesod-auth` and `yesod-auth-oauth2` build and boot; `test-vendor` serves a
minimal app with the GitHub plugin and checks that `/auth/login` returns 200.
The OAuth flow needs an HTTP client for the token exchange and the user info
request, and the stock `http-client` managers cannot connect on Workers. Use the
`Manager` from `newFetchManager` (package `http-client-cloudflare`, see
[http-client.md](http-client.md)). yesod-auth's default `authHttpManager` is the
global manager from `http-client-tls`, which does not work here, so either
override `authHttpManager`:

```haskell
import Network.HTTP.Client.Cloudflare (newFetchManager)

main = runCloudflareWith $ \env -> do
  manager <- newFetchManager
  clientId <- Env.var env "GITHUB_CLIENT_ID"
  clientSecret <- Env.var env "GITHUB_CLIENT_SECRET"
  toWaiAppPlain (App manager clientId clientSecret)

instance YesodAuth App where
  authHttpManager = getsYesod appHttpManager
  authPlugins app = [oauth2GitHub (appClientId app) (appClientSecret app)]
```

or call `Network.HTTP.Client.TLS.setGlobalManager =<< newFetchManager` once at
startup, so everything that uses the global manager goes through fetch.

### Checking GitHub login by hand

Not automated, because it needs real GitHub credentials. `<target>` below is
your own app: wired as in the snippet above and added as an executable to
`cabal.project`. No target in this repo reads `GITHUB_CLIENT_ID` or
`GITHUB_CLIENT_SECRET`.

1. Register a GitHub OAuth App. For local dev the callback URL is
   `http://localhost:8787/auth/page/github/callback`.
2. Create `worker/.dev.vars` with `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`
   and `SESSION_KEY`, one `NAME=value` per line. wrangler hands them to the
   Worker, where `Env.var` reads them as above. `.dev.vars` is in
   `.gitignore`; never commit it.
3. Build the app with `scripts/build.sh <target>`, which writes
   `worker/generated/`.
4. Run `cd worker && npm run dev`.
5. Open `/auth/login`, follow the GitHub link, approve, and confirm the app
   shows you logged in.

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
