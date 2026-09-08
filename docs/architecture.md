# Architecture

The Haskell code is compiled by GHC's wasm backend to a **wasm32-wasi reactor
module**. A reactor module, unlike a command module, has no entry point of its
own and stays alive between calls — exactly the shape a Worker needs.

```
worker/src/index.mjs           Workers fetch handler (JavaScript)
  |  instantiates once per isolate
  +-- worker/src/wasi.mjs      minimal wasi_snapshot_preview1 shim
  +-- generated/ghc_wasm_jsffi.js   JSFFI glue, emitted by post-link.mjs
  +-- generated/app.wasm       the Haskell program
        |
        |  exports: waiMain, handleRequest
        v
haskell/wai-handler-cloudflare
  Network.Wai.Handler.Cloudflare
    runCloudflare      :: Application -> IO ()   -- register
    handleRequest      :: JSVal -> IO JSVal      -- exported to JavaScript
    fromWorkerRequest  :: JSVal -> IO Request
    toWorkerResponse   :: Response -> IO JSVal
        |
        v
haskell/demo-wai               a bare WAI Application
haskell/demo-yesod             a minimal Yesod application
haskell/shims/*                stand-ins for packages that lack a wasm build
```

## Request lifecycle

1. **First request in an isolate** — `index.mjs` instantiates the wasm module.
   The `ghc_wasm_jsffi` import object needs to reach the instance's exports,
   which do not exist yet, so GHC's documented knot-tying trick is used: pass an
   empty object, then `Object.assign` the exports into it afterwards.
2. `wasi.initialize(instance)` calls the module's `_initialize` export exactly
   once, which runs the wasm constructors and brings up the Haskell RTS.
3. `await instance.exports.waiMain()` runs the application's `main`, which calls
   `runCloudflare app`. That stores the `Application` and returns immediately —
   there is no accept loop to enter.
4. **Every request** — `instance.exports.handleRequest(request)` is called with
   the JavaScript `Request`. JSFFI exports are asynchronous by default, so this
   returns a `Promise<Response>`, which is exactly what `fetch` may return.

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
foreign export javascript "waiMain" main :: IO ()
```

The registered `Application` lives in an `IORef` inside the Haskell heap. Nothing
is written to `globalThis`, and the JavaScript side only ever touches the wasm
instance's own exports.

WAI's continuation-passing shape — `Application = Request -> (Response -> IO
ResponseReceived) -> IO ResponseReceived` — cannot be observed from JavaScript,
so `handleRequest` passes a continuation that captures the `Response` and then
converts it.

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

**Request bodies.** The reverse, and asynchronous because the body has to be
awaited:

```haskell
foreign import javascript safe
  "const b = await $1.arrayBuffer(); return new Uint8Array(b);"
  js_reqBody :: JSVal -> IO JSVal
```

Only the calling Haskell thread suspends on the promise. A second, synchronous
import then writes the `Uint8Array` into a freshly allocated `ByteString`.

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

- **argv / environ** — an empty environment and a single fake argv entry
- **clocks** — `Date.now()`, which Workers deliberately keeps coarse
- **stdout / stderr** — line-buffered into `console.log` / `console.error`
- **filesystem** — none. `fd_prestat_get` returns `EBADF` for fd 3, which is how
  libc learns there are no preopened directories
- **everything else** — reported by name the first time it is called, rather than
  letting instantiation supply `undefined`
