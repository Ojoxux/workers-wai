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

`rts/Main.h` already declares `hs_main`. Hence `waiMain`. Any name in the RTS's C
namespace is a hazard; avoid the `hs_` prefix entirely.

## JSFFI exports do not need `-optl-Wl,--export`

GHC emits the wasm exports for `foreign export javascript` automatically.
`scripts/inspect-wasm.mjs` confirms `waiMain` and `handleRequest` are both
present with only:

```
-no-hs-main -optl-mexec-model=reactor
```

The `--export` linker flags that the GHC user's guide describes are needed for
plain reactor exports, not for JSFFI ones.

## The WASI surface is version- and dependency-dependent

These builds import 20 and 21 `wasi_snapshot_preview1` functions respectively —
`demo-yesod` additionally needs `path_unlink_file`. Neither imports `random_get`,
`sched_yield` or `clock_res_get`, all of which a hand-written shim would
plausibly have guessed at and implemented for nothing.

The set moves with the GHC version and with what the dependency tree touches, so
it must be read off the compiled module rather than assumed. See
[development.md](development.md).

## No filesystem

`fd_prestat_get` returns `EBADF` for fd 3, which is how libc learns there are no
preopened directories and stops probing. `stdout` and `stderr` are line-buffered
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
