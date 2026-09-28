# Architecture

The Haskell code is compiled by GHC's wasm backend to a **wasm32-wasi reactor
module**. A reactor module, unlike a command module, has no entry point of its
own and stays alive between calls — exactly the shape a Worker needs.

```
worker/src/index.mjs           Workers entry: makeWorker(wasm, jsffi)
worker/src/runtime.mjs         makeWorker: boot once per isolate, forward fetch
  +-- worker/src/wasi.mjs      minimal wasi_snapshot_preview1 shim
  +-- generated/ghc_wasm_jsffi.js   JSFFI glue, emitted by post-link.mjs
  +-- generated/app.wasm       the Haskell program
        |
        |  exports: setEnv, workerMain, handleRequest
        v
haskell/cloudflare-workers     typed Workers bindings
  Cloudflare.Workers.Entry     runWorker :: (Env -> IO Handler) -> IO ()
  Cloudflare.Workers.Fetch     Request / Body / Response, fetch
  Cloudflare.Workers.Env       var, lookupVar
  Cloudflare.Workers.Context   waitUntil
        |
        v
haskell/wai-handler-cloudflare runCloudflareWith :: (Env -> IO Application) -> IO ()
        |
        v
haskell/demo-wai, demo-yesod   WAI / Yesod applications
haskell/test-worker            one route per cloudflare-workers behaviour
haskell/shims/*                stand-ins for packages that lack a wasm build
```

## Request lifecycle

1. **First request in an isolate** — `makeWorker` copies the string entries
   of `env` into the WASI environ (unless `envAsEnviron: false`), then
   instantiates the module, tying the JSFFI knot: an empty object is passed
   as the exports table and filled in afterwards.
2. `wasi.initialize(instance)` calls `_initialize` once: wasm constructors and
   the Haskell RTS.
3. `setEnv(env)` hands the env object to `Cloudflare.Workers.Entry`.
4. `workerMain()` runs the application's `main`, which calls `runWorker` (or
   `runCloudflareWith`). That builds the handler from the env, stores it, and
   returns.
5. **Every request** — `handleRequest(request, ctx)` converts the JS
   `Request`, runs the handler, and converts the result. JSFFI exports are
   asynchronous, so JavaScript receives a `Promise<Response>`. An exception
   becomes a 500 and is written to `console.error`.

Instantiation is deferred to the first request rather than done at module scope,
so it is billed as request time instead of counting against the much tighter
startup CPU time limit. The promise is cached, so concurrent first requests share
one boot; a failed boot clears the cache so the next request retries rather than
wedging the isolate.

For GHC 9.12 this sequence — instantiate, knot-tie, `_initialize`, call exports —
is complete. There is no separate JSFFI init function to invoke.

## Why the application is registered rather than exported

The API is the natural one:

```haskell
main :: IO ()
main = do
  app <- toWaiAppPlain App
  runCloudflare app
```

A reactor module cannot run `main` by itself, so the application module exports
it explicitly — the one wasm-specific line an application needs:

```haskell
foreign export javascript "workerMain" main :: IO ()
```

The handler lives in an `IORef` inside `Cloudflare.Workers.Entry`, next to the
env. `setEnv` and `handleRequest` are exported by the library, so the
application still writes exactly one `foreign export`.

WAI's continuation-passing shape — `Application = Request -> (Response -> IO
ResponseReceived) -> IO ResponseReceived` — cannot be observed from JavaScript,
so `serve`, in `Network.Wai.Handler.Cloudflare` (haskell/wai-handler-cloudflare),
passes the `Application` a continuation that captures the `Response` it is
given into an `IORef`, then converts that into a `Cloudflare.Workers.Fetch.Response`.
That conversion is what `runCloudflareWith` registers as the `Handler`;
`Cloudflare.Workers.Entry.handleRequest` just calls it and hands the result
back to JavaScript.

## Crossing the FFI boundary

`JSVal` cannot carry a `ByteString`, so bytes move through wasm linear memory
directly.

**Response bodies.** `unsafeUseAsCStringLen` hands the pointer to a
*synchronous* (`unsafe`) JSFFI import:

```haskell
foreign import javascript unsafe
  "new Uint8Array(new Uint8Array(__exports.memory.buffer, $1, $2))"
  js_copyBytes :: Int -> Int -> IO JSVal
```

The outer constructor copies, so the result stays valid after the Haskell buffer
is collected. A synchronous import cannot trigger a GC, which is what makes the
raw pointer sound — the same guarantee an `unsafe` C FFI call relies on.

**Request bodies.** The reverse, and read lazily: a JavaScript body is not
awaited when a `Request` or `Response` is converted, only when
`Cloudflare.Workers.Fetch.bytes` (or `text`) is actually called, through an
asynchronous (`safe`) import:

```haskell
foreign import javascript safe "return new Uint8Array(await $1.arrayBuffer());"
  js_readBytes :: JSVal -> IO JSVal
```

Only the calling Haskell thread suspends on the promise. A second, synchronous
import then copies the `Uint8Array` into a freshly allocated `ByteString`. A
`cloudflare-workers` handler that never calls `bytes`/`text` never awaits the
request body at all; `wai-handler-cloudflare`'s `toWaiRequest` calls `F.bytes`
up front, so a WAI `Application` always sees the body read in full before it
runs.

**Headers.** Encoded as a single NUL-separated string of alternating names and
values. A NUL can never appear in an HTTP header, and this keeps a JSON library
out of the handler's dependency set.

## The WASI shim

Cloudflare Workers has no WASI layer. `worker/src/wasi.mjs` implements
`wasi_snapshot_preview1` directly rather than pulling in
`@cloudflare/workers-wasi`, which is unmaintained and lacks `initialize()` —
its absence forces a dummy `_start` workaround that several older write-ups
describe.

The implemented set is read off the compiled module rather than assumed; see
[development.md](development.md). Broadly:

- **argv / environ** — a single fake argv entry, and an environ built from the
  string-valued entries of the Worker's `env` (unless `makeWorker` is called
  with `envAsEnviron: false`, in which case it is empty)
- **clocks** — `Date.now()`, which Workers deliberately keeps coarse
- **stdout / stderr** — line-buffered into `console.log` / `console.error`
- **filesystem** — none. `fd_prestat_get` returns `EBADF` for fd 3, which is how
  libc learns there are no preopened directories
- **everything else** — reported by name the first time it is called, rather than
  letting instantiation supply `undefined`
