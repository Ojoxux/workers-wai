# Vendored packages

Hackage packages patched to build, link and run on GHC 9.12's wasm32-wasi
backend. Each directory is the unmodified Hackage source (`cabal get`) with
`patches/<package>.diff` applied; the diff is the authoritative record of what
changed. `cabal.project` lists them as local packages, which shadows Hackage.

| Package | Why it is patched | Upstream |
|---|---|---|
| basement 0.0.16 | `cbits/foundation_system.h` errors on any OS but Windows, macOS, Linux and generic Unix; it now has a `__wasi__` branch. Its 32-bit code paths no longer compiled on GHC ≥ 9.4 (`GHC.IntWord64` imports, `Word32#`/`Word#` conversions). | Unmaintained since 2023: kept here. |
| memory 0.18.0 | `Data.Memory.MemMap.Posix` needs `mmap`; it is internal and dropped on wasi. 32-bit `CompatPrim64` fixed for GHC ≥ 9.4 (compile-only: no vendored module imports it, so nothing runs it). `memcpy`/`memset` FFI declared with the C return type, which wasm-ld enforces. | Unmaintained since 2022: kept here. Replaces the former `haskell/shims/memory`. |
| cborg 0.2.10.0 | Its `ARCH_32bit` code had bit-rotted (type errors, a syntax error, `GHC.IntWord64`). Needed by `tls` through `serialise`. | Maintained: to be offered upstream. |
| crypton 1.0.6 | argon2 built without threads; a WASI entropy backend using `getentropy` (the `random_get` import) — without it every random operation fails; curve25519/x448 FFI declared with the C return type. | Maintained: to be offered upstream. |
| xml-conduit 1.10.1.0 | Its cabal-doctest `Setup.hs` links against the threaded RTS, which wasm has not; switched to `build-type: Simple`. Needed by `authenticate`, which `yesod-auth` uses. | Maintained: to be offered upstream. |

The 32-bit fixes run code paths that are rarely exercised; `haskell/test-vendor`
checks them against published vectors. `/vectors` returns `ok 77` when all of
these pass:

- crypton: SHA-256 of "abc", the AES-128 block cipher (FIPS-197 C.1),
  HMAC-SHA256 (RFC 4231 test cases 1 and 2), X25519 and X448 (RFC 7748).
- memory: `constEq` on equal and unequal input, and a `convert` round trip.
- cborg, 61 RFC 8949 checks (34 encode, byte for byte; 27 decode, value
  compared): word64 and int64 boundaries (0 to 2^64-1, -1 to -2^63), one
  integer beyond int64 (-2^64), double 1.1, 1.0e300 and -4.1, float 100000.0,
  a byte string, a string, an array and a map. Decoding is checked for every
  word64 and int64 value, the integer and the double 1.1.
- cborg canonical and offset decoders, 7 more checks (9 crypto and memory
  checks, 61 above and these 7 make 77): `decodeWord64Canonical` rejects
  `1b0000000000000017` and accepts `1affffffff`, `decodeInt64` reads
  `1b7fffffffffffffff` and `1a80000000`, `decodeInt64Canonical` accepts
  `3a7fffffff` (-2147483648) and rejects `3a00000000`, and
  `peekByteOffset` is 1 after decoding `17` from `1718`.

Three more routes cover what the vectors cannot: `/random` (crypton randomness
through `random_get`), `/clientsession` (a real clientsession encrypt/decrypt
round trip, and a tampered cookie is rejected) and `/auth/login` (a minimal
yesod-auth app with the GitHub OAuth2 plugin boots and serves its login page).
`scripts/test.sh` runs all of them under Node and `scripts/check-wrangler.mjs`
under workerd.

Not covered: memory's `CompatPrim64` fix, which only has to compile, and the
OAuth login flow itself, which needs an HTTP client that reaches the network.
clientsession is checked by a round trip and a tamper test, not by vectors.

Not yet checked against vectors, to be added when a feature relies on them:
P-256, Ed25519, ChaCha20-Poly1305, AES-GCM and AES-CTR, SHA-512, Skein-MAC,
bcrypt and argon2, and the rest of cborg. Passing these checks says nothing
about those.

## Using these packages from another repository

```
source-repository-package
  type: git
  location: https://github.com/Ojoxux/workers-wai
  tag: <a commit>
  subdir: haskell/vendor/crypton-1.0.6
          haskell/vendor/memory-0.18.0
          haskell/vendor/basement-0.0.16
          haskell/vendor/cborg-0.2.10.0
          haskell/vendor/xml-conduit-1.10.1.0
```

Use the same `constraints:` as this repository's `cabal.project`.

## Known loose ends

- xml-conduit's doctest test-suite stanza is broken under `--enable-tests`,
  because `Setup` is now `Simple`. Do not enable its tests.
- crypton's `Crypto/Internal/Endian.hs` defaults to big-endian when
  `ARCH_IS_LITTLE_ENDIAN` is unset, which is the case on wasm32. Nothing uses it
  today. If a future version does, patch it with `|| arch(wasm32)`.

## Size

The `test-vendor` wasm is about 9.8 MiB (10,267,236 bytes). That includes
yesod-auth, yesod-auth-oauth2 and the whole crypto stack; the Workers limit is
64 MiB uncompressed.

To update a package: `cabal get` the new version next to the old one, apply the
old diff, fix what does not apply, regenerate the diff against a pristine copy,
and replace the directory.
