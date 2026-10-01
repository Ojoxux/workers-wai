# Shims

`yesod-core`'s dependency tree contains packages that cannot be compiled for
`wasm32-wasi`. `haskell/shims/` replaces two of them, `network` and `entropy`; `cabal.project`
lists them as local packages, which shadows Hackage. Each shim's `.cabal` file carries the
same explanation as this document.

Two more packages used to be shimmed here, `memory` and `clientsession`. Both are
gone: `memory` is now the real package, vendored with a small patch, and
`clientsession` is the real package from Hackage, built over the vendored
`crypton`. See [Patched, not replaced](#patched-not-replaced).

Each shim keeps the version number of the release it stands in for, so that
dependency bounds resolve normally.

## The two

| Shim | Why the real one fails | Faithfulness |
|---|---|---|
| `network` | wasi-libc ships `sys/socket.h` but no `netdb.h`, so `HsNet.h` fails on undeclared `getaddrinfo` / `getnameinfo` / `freeaddrinfo` | **Partial.** Address types are real, because WAI genuinely uses `SockAddr`. Socket operations raise a descriptive error. |
| `entropy` | its custom `Setup.hs` link-tests against `-lHSrts-1.0.3_thr`; there is no threaded RTS for wasm | **Real.** Backed by the host's `crypto.getRandomValues` through JSFFI, which is a CSPRNG. |

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

## `entropy` is a real implementation

It is not a stub, and it matters. `getEntropy` seeds `yesod-core`'s random number
generation. The Workers runtime exposes `crypto.getRandomValues`, which is
cryptographically secure, so the shim calls it through JSFFI and chunks the
request to respect the 65536-byte limit. This is strictly better than a stub
that throws: the functionality is genuinely available on this platform, just not
through the path the real package takes.

`crypton` does not use this package. Its randomness comes from WASI
`random_get`, through a vendored backend (see [constraints.md](constraints.md)).

## Patched, not replaced

A shim fakes an API: the package keeps its name and version, but the code is
written from scratch and may do less than the original. A vendored package is
the real code with a small patch, so it behaves like the original wherever the
patch does not reach. Packages that only needed a patch to build live in
`haskell/vendor/` (`basement`, `memory`, `cborg`, `crypton`, `xml-conduit`);
`haskell/vendor/README.md` says what each patch changes and why.

`memory` and `clientsession` moved from the first group to the second. The
former `memory` shim implemented only `constEq`; the real `memory` provides the
whole API, and `yesod-core`'s CSRF check still uses its `constEq`. The former
`clientsession` shim raised an error on every call; the real one works, so
`defaultClientSessionBackend` and `envClientSessionBackend` work too (see
[yesod.md](yesod.md)). Because the vendored code includes 32-bit paths that
nobody had run, `haskell/test-vendor` checks it against published vectors.

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
