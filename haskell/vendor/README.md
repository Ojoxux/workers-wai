# Vendored packages

Hackage packages patched to build, link and run on GHC 9.12's wasm32-wasi
backend. Each directory is the unmodified Hackage source (`cabal get`) with
`patches/<package>.diff` applied; the diff is the authoritative record of what
changed. `cabal.project` lists them as local packages, which shadows Hackage.

| Package | Why it is patched | Upstream |
|---|---|---|
| basement 0.0.16 | `cbits/foundation_system.h` errors on any OS but Windows, macOS, Linux and generic Unix; it now has a `__wasi__` branch. Its 32-bit code paths no longer compiled on GHC ≥ 9.4 (`GHC.IntWord64` imports, `Word32#`/`Word#` conversions). | Unmaintained since 2023: kept here. |
| memory 0.18.0 | `Data.Memory.MemMap.Posix` needs `mmap`; it is internal and dropped on wasi. 32-bit `CompatPrim64` fixed for GHC ≥ 9.4. `memcpy`/`memset` FFI declared with the C return type, which wasm-ld enforces. | Unmaintained since 2022: kept here. Replaces the former `haskell/shims/memory`. |
| cborg 0.2.10.0 | Its `ARCH_32bit` code had bit-rotted (type errors, a syntax error, `GHC.IntWord64`). Needed by `tls` through `serialise`. | Maintained: to be offered upstream. |
| crypton 1.0.6 | argon2 built without threads; a WASI entropy backend using `getentropy` (the `random_get` import) — without it every random operation fails; curve25519/x448 FFI declared with the C return type. | Maintained: to be offered upstream. |
| xml-conduit 1.10.1.0 | Its cabal-doctest `Setup.hs` links against the threaded RTS, which wasm has not; switched to `build-type: Simple`. Needed by `authenticate`, which `yesod-auth` uses. | Maintained: to be offered upstream. |

The 32-bit fixes run code paths that are rarely exercised; `haskell/test-vendor`
checks them against published vectors (RFC 8949 for CBOR, FIPS-197, RFC 4231,
RFC 7748 for crypton).

To update a package: `cabal get` the new version next to the old one, apply the
old diff, fix what does not apply, regenerate the diff against a pristine copy,
and replace the directory.
