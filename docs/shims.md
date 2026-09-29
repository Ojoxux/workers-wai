# Shims

`yesod-core`'s dependency tree contains packages that cannot be compiled for
`wasm32-wasi`. `haskell/shims/` replaces four of them; `cabal.project` lists them
as local packages, which shadows Hackage. Each shim's `.cabal` file carries the
same explanation as this document.

Each shim keeps the version number of the release it stands in for, so that
dependency bounds resolve normally.

## The four

| Shim | Why the real one fails | Faithfulness |
|---|---|---|
| `network` | wasi-libc ships `sys/socket.h` but no `netdb.h`, so `HsNet.h` fails on undeclared `getaddrinfo` / `getnameinfo` / `freeaddrinfo` | **Partial.** Address types are real, because WAI genuinely uses `SockAddr`. Socket operations raise a descriptive error. |
| `entropy` | its custom `Setup.hs` link-tests against `-lHSrts-1.0.3_thr`; there is no threaded RTS for wasm | **Real.** Backed by the host's `crypto.getRandomValues` through JSFFI, which is a CSPRNG. |
| `memory` | depends on `basement`, whose `cbits/foundation_system.h` dispatches on `_WIN32` / `__APPLE__` / `__linux__` / `__unix__` and errors on anything else; wasi-sdk's clang defines `__wasi__`, which it has never heard of | **Real.** `yesod-core` uses exactly one function, `constEq`, reimplemented as a genuine constant-time comparison. |
| `clientsession` | needs AES and Skein via `crypton` → `memory` → `basement` | **Fictional.** Every operation raises an error. Applications use `Yesod.Cloudflare.Session` instead. |

## `network` is the load-bearing one

It is what lets `recv`, `streaming-commons`, `http-semantics`, `http2`,
`iproute`, `warp`, `wai-extra` and `wai-logger` compile. Before it existed in its
current form, six packages failed; afterwards, none of those did.

Note that `yesod-core` depends on **`warp` directly** and imports
`Network.Wai.Handler.Warp`, so a socket API has to exist at compile time even
though the platform has none. This is the least uncomfortable fiction in the set:
on Cloudflare Workers the runtime owns the connection, so none of that code can
ever run, and an error at the point of use is the honest outcome.

The API surface was derived by grepping the actual imports of every consumer,
not by guessing. Two modules are needed: `Network.Socket` and
`Network.Socket.ByteString`.

## `memory` and `entropy` are real implementations

Neither is a stub, and it matters in both cases.

`constEq` is what `yesod-core` uses to compare CSRF tokens. A naive `==` would
short-circuit on the first differing byte and silently reintroduce a timing
side channel, so the replacement XORs every byte:

```haskell
constEq a b =
  B.length xs == B.length ys
    && foldl' (\acc (p, q) -> acc .|. (p `xor` q)) 0 (B.zip xs ys) == 0
```

Length is compared first and does leak, exactly as in the real implementation —
the length of a token is not the secret.

`getEntropy` seeds `yesod-core`'s random number generation. The Workers runtime
exposes `crypto.getRandomValues`, which is cryptographically secure, so the shim
calls it through JSFFI and chunks the request to respect the 65536-byte limit.
This is strictly better than a stub that throws: the functionality is genuinely
available on this platform, just not through the path the real package takes.

## `clientsession` is the one real fiction

It provides no cryptography, and every operation raises an error. Applications
do not use it: they use `Yesod.Cloudflare.Session` from `yesod-cloudflare`, a
session backend on WebCrypto AES-GCM (see [yesod.md](yesod.md)). The shim remains
only because `yesod-core` depends on `clientsession` at build time. An
application that used `defaultClientSessionBackend` would fail at runtime with an
error explaining the situation, rather than at compile time.

Porting `basement` to WASI would be the other way to make the real package
build, but the Workers runtime has AES-GCM natively, so the WebCrypto backend is
both real and simpler.

## One flag, not a shim

`warp`'s `x509` flag defaults on and pulls in `crypton-x509` → `crypton` → `ram`,
which needs `mmap` and `TIOCGWINSZ` — neither of which WASI has. The flag only
enables reading TLS client certificates, and Cloudflare terminates TLS upstream,
so `cabal.project` turns it off:

```
package warp
  flags: -x509
```

## What builds unmodified

Everything else in the tree, including `zlib`, `fast-logger`, `unix-compat`,
`ansi-terminal`, `aeson`, `shakespeare`, `conduit` and `unix`. The set of
genuinely wasm-hostile packages is much smaller than it first appears — the
failures cascade, so one broken leaf looks like a dozen.
