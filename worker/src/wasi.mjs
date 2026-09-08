// A minimal wasi_snapshot_preview1 implementation, just enough to bring up
// GHC's RTS inside the Cloudflare Workers runtime.
//
// Workers has no WASI layer of its own, and @cloudflare/workers-wasi is
// unmaintained and lacks initialize().
//
// The function list below is not a guess: it is exactly the set of
// wasi_snapshot_preview1 imports that the current build requires, as reported
// by
//
//     node scripts/inspect-wasm.mjs worker/generated/app.wasm
//
// GHC pulls in a different set depending on its version and on what the
// dependency tree touches, so re-run that after changing either. Anything
// imported but not implemented here is reported by name the first time it is
// called (see `missing`) rather than silently returning undefined.

// wasi_snapshot_preview1 errno values.
const ESUCCESS = 0;
const EBADF = 8;
const ENOSYS = 52;
const ESPIPE = 70;

const FILETYPE_CHARACTER_DEVICE = 2;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function createWasi({ args = ["app.wasm"], env = {} } = {}) {
  let memory = null;

  const view = () => new DataView(memory.buffer);
  const bytes = () => new Uint8Array(memory.buffer);

  // stdout/stderr are line-buffered into console.log/console.error. A trailing
  // partial line is dropped, which is fine: the RTS only writes here for
  // diagnostics.
  const pending = new Map([
    [1, ""],
    [2, ""],
  ]);

  function writeText(fd, text) {
    const sink = fd === 2 ? console.error : console.log;
    let buffered = (pending.get(fd) ?? "") + text;
    let nl;
    while ((nl = buffered.indexOf("\n")) !== -1) {
      sink(buffered.slice(0, nl));
      buffered = buffered.slice(nl + 1);
    }
    pending.set(fd, buffered);
  }

  const missing = new Set();

  const impl = {
    // -- process ------------------------------------------------------------

    proc_exit(code) {
      throw new Error(`wasi: proc_exit(${code}) -- the Haskell RTS terminated`);
    },

    // -- argv / environ -----------------------------------------------------

    args_sizes_get(argcPtr, argvBufSizePtr) {
      const dv = view();
      dv.setUint32(argcPtr, args.length, true);
      dv.setUint32(
        argvBufSizePtr,
        args.reduce((n, a) => n + encoder.encode(a).length + 1, 0),
        true,
      );
      return ESUCCESS;
    },

    args_get(argvPtr, argvBufPtr) {
      const dv = view();
      const mem = bytes();
      let bufOffset = argvBufPtr;
      args.forEach((arg, i) => {
        dv.setUint32(argvPtr + i * 4, bufOffset, true);
        const encoded = encoder.encode(arg);
        mem.set(encoded, bufOffset);
        mem[bufOffset + encoded.length] = 0;
        bufOffset += encoded.length + 1;
      });
      return ESUCCESS;
    },

    environ_sizes_get(countPtr, bufSizePtr) {
      const entries = Object.entries(env);
      const dv = view();
      dv.setUint32(countPtr, entries.length, true);
      dv.setUint32(
        bufSizePtr,
        entries.reduce((n, [k, v]) => n + encoder.encode(`${k}=${v}`).length + 1, 0),
        true,
      );
      return ESUCCESS;
    },

    environ_get(environPtr, environBufPtr) {
      const dv = view();
      const mem = bytes();
      let bufOffset = environBufPtr;
      Object.entries(env).forEach(([k, v], i) => {
        dv.setUint32(environPtr + i * 4, bufOffset, true);
        const encoded = encoder.encode(`${k}=${v}`);
        mem.set(encoded, bufOffset);
        mem[bufOffset + encoded.length] = 0;
        bufOffset += encoded.length + 1;
      });
      return ESUCCESS;
    },

    // -- clocks -------------------------------------------------------------
    //
    // Workers freezes Date.now() between I/O operations as a timing-attack
    // mitigation, so this is coarse. Nothing in the request path depends on
    // fine-grained time.

    clock_time_get(_clockId, _precision, timePtr) {
      view().setBigUint64(timePtr, BigInt(Date.now()) * 1_000_000n, true);
      return ESUCCESS;
    },

    // -- file descriptors ---------------------------------------------------
    //
    // Only stdin/stdout/stderr exist, and they behave as character devices.

    fd_write(fd, iovsPtr, iovsLen, nwrittenPtr) {
      if (fd !== 1 && fd !== 2) return EBADF;
      const dv = view();
      const mem = bytes();
      let written = 0;
      for (let i = 0; i < iovsLen; i++) {
        const bufPtr = dv.getUint32(iovsPtr + i * 8, true);
        const bufLen = dv.getUint32(iovsPtr + i * 8 + 4, true);
        if (bufLen === 0) continue;
        writeText(fd, decoder.decode(mem.subarray(bufPtr, bufPtr + bufLen)));
        written += bufLen;
      }
      dv.setUint32(nwrittenPtr, written, true);
      return ESUCCESS;
    },

    fd_read(fd, _iovsPtr, _iovsLen, nreadPtr) {
      if (fd !== 0) return EBADF;
      view().setUint32(nreadPtr, 0, true); // immediate EOF
      return ESUCCESS;
    },

    fd_close(fd) {
      return fd >= 0 && fd <= 2 ? ESUCCESS : EBADF;
    },

    fd_seek(_fd, _offset, _whence, _newOffsetPtr) {
      return ESPIPE; // character devices are not seekable
    },

    fd_fdstat_get(fd, statPtr) {
      if (fd < 0 || fd > 2) return EBADF;
      const dv = view();
      // fdstat: u8 filetype, u8 pad, u16 flags, u32 pad,
      //         u64 rights_base, u64 rights_inheriting
      dv.setUint8(statPtr, FILETYPE_CHARACTER_DEVICE);
      dv.setUint8(statPtr + 1, 0);
      dv.setUint16(statPtr + 2, 0, true);
      dv.setUint32(statPtr + 4, 0, true);
      dv.setBigUint64(statPtr + 8, 0n, true);
      dv.setBigUint64(statPtr + 16, 0n, true);
      return ESUCCESS;
    },

    fd_fdstat_set_flags(_fd, _flags) {
      return ESUCCESS;
    },

    fd_filestat_get(_fd, _statPtr) {
      return EBADF;
    },

    fd_filestat_set_size(_fd, _size) {
      return EBADF;
    },

    // No preopened directories: libc stops probing as soon as fd 3 reports
    // EBADF, which is how "sandbox with no filesystem" is expressed.
    fd_prestat_get(_fd, _prestatPtr) {
      return EBADF;
    },

    fd_prestat_dir_name(_fd, _pathPtr, _pathLen) {
      return EBADF;
    },

    // -- paths --------------------------------------------------------------
    //
    // There is no filesystem. These exist only because libc's stdio references
    // them; nothing in the request path calls them.

    path_open() {
      return EBADF;
    },

    path_filestat_get() {
      return EBADF;
    },

    path_create_directory() {
      return EBADF;
    },

    // Imported by the Yesod build but not by the plain WAI one -- a concrete
    // example of why this list is read off the wasm rather than guessed at.
    path_unlink_file() {
      return EBADF;
    },

    // -- polling ------------------------------------------------------------
    //
    // The RTS drives its scheduler through the JSFFI `scheduleWork` import
    // rather than through WASI polling, so this is never reached in practice.

    poll_oneoff(_inPtr, _outPtr, _nsubscriptions, _neventsPtr) {
      return ENOSYS;
    },
  };

  // Report anything the module imports that is not implemented above, instead
  // of letting instantiation hand it `undefined`.
  const imports = new Proxy(impl, {
    get(target, name) {
      if (name in target) return target[name];
      if (typeof name !== "string") return undefined;
      return (...callArgs) => {
        if (!missing.has(name)) {
          missing.add(name);
          console.error(
            `wasi: unimplemented import "${name}" called with ${callArgs.length} args; returning ENOSYS. ` +
              `Add it to worker/src/wasi.mjs.`,
          );
        }
        return ENOSYS;
      };
    },
    has() {
      return true;
    },
  });

  return {
    imports,

    /** Run the reactor module's `_initialize` export exactly once. */
    initialize(instance) {
      memory = instance.exports.memory;
      instance.exports._initialize();
    },

    /** Names imported but not implemented, populated as they are called. */
    missing,
  };
}
