# Technical constraints

Platform limits, and the traps found while building this.

## Export names must not collide with RTS C symbols

`foreign export javascript "hs_main"` fails at the C compilation step:

```
error: conflicting types for 'hs_main'
   11 | HsJSVal hs_main(void)
rts/Main.h:15:5: note: previous declaration is here
   15 | int hs_main (int argc, char *argv[], ...
```

`rts/Main.h` already declares `hs_main`. Hence exports are named `setEnv`,
`workerMain` and `handleRequest` instead. Any name in the RTS's C namespace is
a hazard; avoid the `hs_` prefix entirely.

## JSFFI exports do not need `-optl-Wl,--export`

GHC emits the wasm exports for `foreign export javascript` automatically.
`scripts/inspect-wasm.mjs` confirms `setEnv`, `workerMain` and `handleRequest`
are all present with only:

```
-no-hs-main -optl-mexec-model=reactor
```

The `--export` linker flags that the GHC user's guide describes are needed for
plain reactor exports, not for JSFFI ones.

## A JS exception in an `unsafe` import is not a Haskell exception

It unwinds straight through the RTS and out of whichever export was running,
so `catch` never sees it. `unsafe` (synchronous) imports are therefore kept to
snippets that cannot throw — property reads, byte copies. Anything that can
throw (`new Response`, `fetch`, `ctx.waitUntil`) is a `safe` import.

## `JSString` in an import type needs its constructor in scope

Otherwise GHC generates a C stub referring to `HsJSString`, `rts_mkJSString` and `rts_getJSString`, none of which exist, and the package fails to build. `Cloudflare.Workers.Internal.FFI` therefore re-exports `JSString (..)`, and modules declaring imports get it from there.

## Haskell threads that sleep keep a JS timer alive

The wasm RTS implements `threadDelay` with `setTimeout`. Yesod starts
background threads (auto-update caches) that sleep forever, so a Node process
running the module never exits on its own after one request — which is why
`scripts/test.sh` passes `--test-force-exit` to `node --test` (and
`--test-timeout` so a genuine hang still fails the run rather than wedging
it).

Under `wrangler dev`, `demo-yesod` served repeated requests over roughly 25
seconds, including idle periods, with no errors or warnings. Whether those
timers keep firing between requests on workerd — and if so, whether that
costs anything — is not verified; this is an open question, not a claim that
it is harmless.

## `waitUntil` work keeps running after the response on workerd

`scripts/check-wrangler.mjs` checks this under `wrangler dev` (wrangler
4.129.1), with the same expectations as the Node tests:

- `/wait/beacon` returns `queued`, and the upstream then receives the
  `/beacon` fetch made inside `waitUntil`.
- `/wait/hold` returns `queued` while the upstream is still holding the
  `/hold` request open. After the upstream releases it, wrangler logs nothing
  further — no uncaught exception, no `waitUntil:` error.
- A failing `waitUntil` action (`/wait/fail`) is logged by workerd as
  `✘ [ERROR] waitUntil: user error (boom)`, and the request still gets its 200.
  This shows the "nothing logged" check above would have caught a failure.

Outbound `fetch` from the wasm module to an upstream on `127.0.0.1` works
under `wrangler dev` with no extra configuration, and every check that passes
under Node also passes there. No behaviour difference between Node and workerd
has been found.

## Two `wrangler dev` instances collide unless separated

Both configs live in `test/`, so with defaults the two instances share the
inspector port 9229 and the local state at `test/.wrangler/state`. Which one
fails is a race, and either can:

- The second to bind the inspector fails with
  `Address already in use (127.0.0.1:9229)` (observed on the yesod instance).
- Both open the same local SQLite state, and one dies with
  `SQLITE_BUSY_RECOVERY ... database is locked` (observed on the test-worker
  instance).

`scripts/check-wrangler.mjs` gives each instance its own free inspector port and
its own `--persist-to` directory under `.wrangler/state/`.

## A `safe` import's result is a lazy thunk

The effect is not awaited, and a rejection is not raised, until the result is
forced. `try act` alone catches nothing. `Cloudflare.Workers.Internal.FFI`
provides `awaitJS`, which forces the result inside `try` and converts GHC's
`JSException` into a `JSError` with the JS error's name, message and stack:

```haskell
awaitJS :: IO a -> IO a
awaitJS act = do
  result <- try (act >>= evaluate)
  case result of
    Right a                   -> pure a
    Left (Prim.JSException v) -> toJSError v >>= throwIO
```

## The WASI surface is version- and dependency-dependent

The `demo-wai` and `demo-yesod` builds import 20 and 21 `wasi_snapshot_preview1`
functions respectively — `demo-yesod` additionally needs `path_unlink_file`.
Neither imports `random_get`, `sched_yield` or `clock_res_get`, all of which a
hand-written shim would plausibly have guessed at and implemented for nothing.
The crypto stack changes that: `test-vendor` and `test-yesod` (which links the
real clientsession) import `random_get`. `wasi.mjs` also has `fd_readdir` as a
precaution: no current build imports it, but code that reads the system
certificate store would (for example if http-client-tls's store gets linked).

The set moves with the GHC version and with what the dependency tree touches, so
it must be read off the compiled module rather than assumed. See
[development.md](development.md).

## Randomness must come from `random_get`

Stock crypton's system entropy backend only opens `/dev/urandom`. There is no
filesystem, so every random operation (key generation, IVs, nonces) fails. The
vendored crypton adds a backend that calls `getentropy`, which wasi-libc
implements with the WASI `random_get` import, and `worker/src/wasi.mjs` backs
that with `crypto.getRandomValues` in chunks of at most 65,536 bytes. Without
the vendored crypton, anything that needs a random number fails at run time.

## 32-bit code paths in Hackage packages bit-rot

wasm32 is a 32-bit target, so it takes the `ARCH_32bit` and `CompatPrim64`
branches that 64-bit platforms never compile. Those had stopped building:
basement, memory and cborg all needed fixes (see `haskell/vendor/README.md`).
A patch that compiles proves little about code nobody has run, so only what
`haskell/test-vendor` checks against published vectors, under Node and workerd,
should be trusted:

- crypton: SHA-256, the AES-128 block cipher (FIPS-197), HMAC-SHA256
  (RFC 4231 cases 1 and 2), X25519 and X448 (RFC 7748).
- memory: `constEq` and `convert`.
- cborg: an encode and decode subset of RFC 8949 Appendix A, plus checks of the
  32-bit canonical and offset decoders.
- clientsession: an encrypt/decrypt round trip and a tamper check, not vectors.

Not yet checked against vectors: P-256, Ed25519, ChaCha20-Poly1305, AES-GCM and
AES-CTR, SHA-512, Skein-MAC, bcrypt and argon2, and the rest of cborg and
crypton. Add vectors before a feature relies on any of them.

## FFI return types must match the C function exactly

On native targets a wrong return type in a `foreign import ccall` is usually
harmless. wasm-ld checks function signatures: a mismatch is rejected or turned
into a stub, reported as `function signature mismatch`. The `memcpy` and
`memset` imports in memory, and the curve25519 and x448 imports in crypton,
declared a result the C function does not return, and were fixed to match.

## crypton 1.1 and `ram`

crypton 1.1 and later replaced `memory` with `ram`, whose `ByteArrayAccess` is a
different class. `yesod-auth` 1.6.12.1 and `hoauth2` 2.15 are written against the
`memory` class and do not compile against it, on any platform. `cabal.project`
pins `crypton ==1.0.6` and the packages that depend on it (`tls`,
`crypton-connection`, `crypton-x509`, `hoauth2`, `yesod-auth-oauth2`) to the last
combination that does. Moving to `ram` is a separate piece of work.

## No filesystem

`fd_prestat_get` returns `EBADF` for fd 3, which is how libc learns there are no
preopened directories and stops probing; `fd_readdir` returns `EBADF` for the
same reason. `stdout` and `stderr` are line-buffered
into `console.log` and `console.error`; a trailing partial line is dropped, which
is fine because the RTS only writes there for diagnostics.

This is why `responseFile` returns 501.

## No threaded RTS

There is no `HSrts_thr` for wasm. Packages whose `Setup.hs` link-tests against it
— `entropy` is the one encountered here — fail during `configure`, which is a
confusing place to see a linker error.

## Headers are treated as latin-1

Bytes map one-to-one to characters across the FFI boundary, so non-ASCII header
values are not round-tripped faithfully. HTTP header values are ASCII in
practice, and doing better would mean encoding them explicitly on both sides.

## `Date.now()` is coarse

Workers freezes it between I/O operations as a timing-attack mitigation, so
`clock_time_get` is correspondingly imprecise. Nothing in the request path
depends on fine-grained time, but anything that measures short durations inside
a single request will see zero.

## Size limits are no longer the problem

Cloudflare
[removed the compressed-size limit on 2026-09-04](https://developers.cloudflare.com/changelog/post/2026-09-04-increased-worker-size-limit/);
the ceiling is now 64 MiB uncompressed on all plans.

This is worth stating plainly because earlier write-ups of Haskell on Workers
spend most of their effort fighting a 1 MiB compressed budget — disabling GC,
tuning RTS flags, trimming dependencies. None of that is necessary now, and it is
what makes a 4.1 MiB Yesod build unremarkable.

## Workarounds that are no longer needed

Older write-ups patch the generated `ghc_wasm_jsffi.js` because the Workers
runtime lacked `MessageChannel` (used by the `setImmediate` polyfill) and
`FinalizationRegistry` (used to free stable pointers). Both now exist in workerd,
so the generated glue is used unmodified.

Likewise, `@cloudflare/workers-wasi` is not used. It is unmaintained and lacks
`initialize()`, which forces a dummy `_start` workaround. A hand-written shim of
21 functions is smaller and more predictable.
