import "dart:ffi";
import "dart:io" show Platform;

// Utf8 moved out of dart:ffi; package:ffi's is the one Dart 3.13 keeps.
import "package:ffi/ffi.dart";

// The dart:ffi bindings to the iSH bridge (tool/ios/ish/ish_bridge.c). The
// bridge runs the iSH emulator core in-process — see ios/AGENTS.md for why a
// child-process shell cannot work on iOS.
//
// The symbols are linked into the app executable (a static lib, not a dylib),
// so they are looked up through DynamicLibrary.process() — once, on first use,
// and only on iOS. Everywhere else ishLinked is false and nothing below is ever
// called, so the symbol is never looked up and the build carries no iSH.

// The opaque pointer Dart holds for a session.
typedef IshSessionPtr = Pointer<Void>;

// Function pointer types for the bridge entry points.
typedef IshInitC =
    Pointer<Void> Function(
      Pointer<Utf8> rootfsDir,
      Pointer<Utf8> dataDir,
      Pointer<Utf8> home,
      Pointer<Utf8> cwd,
      Pointer<Utf8> dispatcher,
      Pointer<Utf8> token,
      Pointer<Pointer<Utf8>> env,
      Int32 envCount,
      Pointer<Pointer<Utf8>> readOnly,
      Int32 readOnlyCount,
      Pointer<Pointer<Utf8>> error,
    );
typedef IshInitDart =
    IshSessionPtr Function(
      Pointer<Utf8> rootfsDir,
      Pointer<Utf8> dataDir,
      Pointer<Utf8> home,
      Pointer<Utf8> cwd,
      Pointer<Utf8> dispatcher,
      Pointer<Utf8> token,
      Pointer<Pointer<Utf8>> env,
      int envCount,
      Pointer<Pointer<Utf8>> readOnly,
      int readOnlyCount,
      Pointer<Pointer<Utf8>> error,
    );

typedef IshDrainWakeC = Void Function(IshSessionPtr session);
typedef IshDrainWakeDart = void Function(IshSessionPtr session);

typedef IshWriteStdinC =
    Void Function(IshSessionPtr session, Pointer<Utf8> scriptB64);
typedef IshWriteStdinDart =
    void Function(IshSessionPtr session, Pointer<Utf8> scriptB64);

typedef IshPollC = Int32 Function(IshSessionPtr session);
typedef IshPollDart = int Function(IshSessionPtr session);

typedef IshReadC =
    Int32 Function(IshSessionPtr session, Pointer<Uint8> buf, Int32 cap);
typedef IshReadDart =
    int Function(IshSessionPtr session, Pointer<Uint8> buf, int cap);

typedef IshInterruptC = Void Function(IshSessionPtr session);
typedef IshInterruptDart = void Function(IshSessionPtr session);

typedef IshHangupC = Void Function(IshSessionPtr session);
typedef IshHangupDart = void Function(IshSessionPtr session);

typedef IshDestroyC = Void Function(IshSessionPtr session);
typedef IshDestroyDart = void Function(IshSessionPtr session);

typedef IshFakefsifyC =
    Int32 Function(Pointer<Utf8> archive, Pointer<Utf8> into);
typedef IshFakefsifyDart =
    int Function(Pointer<Utf8> archive, Pointer<Utf8> into);

// The pipe-session entry points (a guest program run directly, for the CLI
// providers). IshPipeSessionPtr is the handle Dart holds.
typedef IshPipeSessionPtr = Pointer<Void>;

typedef IshPipeInitC =
    Pointer<Void> Function(
      Pointer<Utf8> rootfsDir,
      Pointer<Utf8> dataDir,
      Pointer<Utf8> home,
      Pointer<Utf8> cwd,
      Pointer<Pointer<Utf8>> argv,
      Int32 argc,
      Pointer<Pointer<Utf8>> env,
      Int32 envCount,
      Pointer<Pointer<Utf8>> readOnly,
      Int32 readOnlyCount,
      Pointer<Pointer<Utf8>> error,
    );
typedef IshPipeInitDart =
    IshPipeSessionPtr Function(
      Pointer<Utf8> rootfsDir,
      Pointer<Utf8> dataDir,
      Pointer<Utf8> home,
      Pointer<Utf8> cwd,
      Pointer<Pointer<Utf8>> argv,
      int argc,
      Pointer<Pointer<Utf8>> env,
      int envCount,
      Pointer<Pointer<Utf8>> readOnly,
      int readOnlyCount,
      Pointer<Pointer<Utf8>> error,
    );

typedef IshPipeWriteC =
    Void Function(IshPipeSessionPtr session, Pointer<Utf8> buf, Int32 len);
typedef IshPipeWriteDart =
    void Function(IshPipeSessionPtr session, Pointer<Utf8> buf, int len);

typedef IshPipeCloseInputC = Void Function(IshPipeSessionPtr session);
typedef IshPipeCloseInputDart = void Function(IshPipeSessionPtr session);

typedef IshPipePollC = Int32 Function(IshPipeSessionPtr session);
typedef IshPipePollDart = int Function(IshPipeSessionPtr session);

typedef IshPipeReadC =
    Int32 Function(
      IshPipeSessionPtr session,
      Int32 stream,
      Pointer<Uint8> buf,
      Int32 cap,
    );
typedef IshPipeReadDart =
    int Function(
      IshPipeSessionPtr session,
      int stream,
      Pointer<Uint8> buf,
      int cap,
    );

typedef IshPipeTerminateC = Void Function(IshPipeSessionPtr session);
typedef IshPipeTerminateDart = void Function(IshPipeSessionPtr session);

typedef IshPipeHangupC = Void Function(IshPipeSessionPtr session);
typedef IshPipeHangupDart = void Function(IshPipeSessionPtr session);

typedef IshPipeDestroyC = Void Function(IshPipeSessionPtr session);
typedef IshPipeDestroyDart = void Function(IshPipeSessionPtr session);

typedef IshPipeExitCodeC = Int32 Function(IshPipeSessionPtr session);
typedef IshPipeExitCodeDart = int Function(IshPipeSessionPtr session);

// The lazy lookups. Null until first use, and only ever resolved on iOS.
IshInitDart? _initFn;
IshDrainWakeDart? _drainWakeFn;
IshWriteStdinDart? _writeStdinFn;
IshPollDart? _pollFn;
IshReadDart? _readFn;
IshInterruptDart? _interruptFn;
IshHangupDart? _hangupFn;
IshDestroyDart? _destroyFn;
IshFakefsifyDart? _fakefsifyFn;

IshPipeInitDart? _pipeInitFn;
IshPipeWriteDart? _pipeWriteFn;
IshPipeCloseInputDart? _pipeCloseInputFn;
IshPipePollDart? _pipePollFn;
IshPipeReadDart? _pipeReadFn;
IshPipeTerminateDart? _pipeTerminateFn;
IshPipeHangupDart? _pipeHangupFn;
IshPipeDestroyDart? _pipeDestroyFn;
IshPipeExitCodeDart? _pipeExitCodeFn;

// The blinkish (x86-64) core's twin entry points. Same signatures, looked up
// by the blinkish_* names the bridge's second core exports.
IshInitDart? _blinkishInitFn;
IshDrainWakeDart? _blinkishDrainWakeFn;
IshWriteStdinDart? _blinkishWriteStdinFn;
IshPollDart? _blinkishPollFn;
IshReadDart? _blinkishReadFn;
IshInterruptDart? _blinkishInterruptFn;
IshHangupDart? _blinkishHangupFn;
IshDestroyDart? _blinkishDestroyFn;

IshPipeInitDart? _blinkishPipeInitFn;
IshPipeWriteDart? _blinkishPipeWriteFn;
IshPipeCloseInputDart? _blinkishPipeCloseInputFn;
IshPipePollDart? _blinkishPipePollFn;
IshPipeReadDart? _blinkishPipeReadFn;
IshPipeTerminateDart? _blinkishPipeTerminateFn;
IshPipeHangupDart? _blinkishPipeHangupFn;
IshPipeDestroyDart? _blinkishPipeDestroyFn;
IshPipeExitCodeDart? _blinkishPipeExitCodeFn;

bool _resolved = false;

void _resolve() {
  if (_resolved) return;
  _resolved = true;
  if (!ishLinked) return;
  final lib = DynamicLibrary.process();
  _initFn = lib.lookupFunction<IshInitC, IshInitDart>("ish_session_init");
  _drainWakeFn = lib.lookupFunction<IshDrainWakeC, IshDrainWakeDart>(
    "ish_session_drain_wake",
  );
  _writeStdinFn = lib.lookupFunction<IshWriteStdinC, IshWriteStdinDart>(
    "ish_session_write_stdin",
  );
  _pollFn = lib.lookupFunction<IshPollC, IshPollDart>("ish_session_poll");
  _readFn = lib.lookupFunction<IshReadC, IshReadDart>("ish_session_read");
  _interruptFn = lib.lookupFunction<IshInterruptC, IshInterruptDart>(
    "ish_session_interrupt",
  );
  _hangupFn = lib.lookupFunction<IshHangupC, IshHangupDart>(
    "ish_session_hangup",
  );
  _destroyFn = lib.lookupFunction<IshDestroyC, IshDestroyDart>(
    "ish_session_destroy",
  );
  _fakefsifyFn = lib.lookupFunction<IshFakefsifyC, IshFakefsifyDart>(
    "ish_fakefsify",
  );
  _pipeInitFn = lib.lookupFunction<IshPipeInitC, IshPipeInitDart>(
    "ish_pipe_init",
  );
  _pipeWriteFn = lib.lookupFunction<IshPipeWriteC, IshPipeWriteDart>(
    "ish_pipe_write",
  );
  _pipeCloseInputFn = lib
      .lookupFunction<IshPipeCloseInputC, IshPipeCloseInputDart>(
        "ish_pipe_close_input",
      );
  _pipePollFn = lib.lookupFunction<IshPipePollC, IshPipePollDart>(
    "ish_pipe_poll",
  );
  _pipeReadFn = lib.lookupFunction<IshPipeReadC, IshPipeReadDart>(
    "ish_pipe_read",
  );
  _pipeTerminateFn = lib
      .lookupFunction<IshPipeTerminateC, IshPipeTerminateDart>(
        "ish_pipe_terminate",
      );
  _pipeHangupFn = lib.lookupFunction<IshPipeHangupC, IshPipeHangupDart>(
    "ish_pipe_hangup",
  );
  _pipeDestroyFn = lib.lookupFunction<IshPipeDestroyC, IshPipeDestroyDart>(
    "ish_pipe_destroy",
  );
  _pipeExitCodeFn = lib.lookupFunction<IshPipeExitCodeC, IshPipeExitCodeDart>(
    "ish_pipe_exit_code",
  );
  _blinkishInitFn = lib.lookupFunction<IshInitC, IshInitDart>(
    "blinkish_session_init",
  );
  _blinkishDrainWakeFn = lib.lookupFunction<IshDrainWakeC, IshDrainWakeDart>(
    "blinkish_session_drain_wake",
  );
  _blinkishWriteStdinFn = lib.lookupFunction<IshWriteStdinC, IshWriteStdinDart>(
    "blinkish_session_write_stdin",
  );
  _blinkishPollFn = lib.lookupFunction<IshPollC, IshPollDart>(
    "blinkish_session_poll",
  );
  _blinkishReadFn = lib.lookupFunction<IshReadC, IshReadDart>(
    "blinkish_session_read",
  );
  _blinkishInterruptFn = lib.lookupFunction<IshInterruptC, IshInterruptDart>(
    "blinkish_session_interrupt",
  );
  _blinkishHangupFn = lib.lookupFunction<IshHangupC, IshHangupDart>(
    "blinkish_session_hangup",
  );
  _blinkishDestroyFn = lib.lookupFunction<IshDestroyC, IshDestroyDart>(
    "blinkish_session_destroy",
  );
  _blinkishPipeInitFn = lib.lookupFunction<IshPipeInitC, IshPipeInitDart>(
    "blinkish_pipe_init",
  );
  _blinkishPipeWriteFn = lib.lookupFunction<IshPipeWriteC, IshPipeWriteDart>(
    "blinkish_pipe_write",
  );
  _blinkishPipeCloseInputFn = lib
      .lookupFunction<IshPipeCloseInputC, IshPipeCloseInputDart>(
        "blinkish_pipe_close_input",
      );
  _blinkishPipePollFn = lib.lookupFunction<IshPipePollC, IshPipePollDart>(
    "blinkish_pipe_poll",
  );
  _blinkishPipeReadFn = lib.lookupFunction<IshPipeReadC, IshPipeReadDart>(
    "blinkish_pipe_read",
  );
  _blinkishPipeTerminateFn = lib
      .lookupFunction<IshPipeTerminateC, IshPipeTerminateDart>(
        "blinkish_pipe_terminate",
      );
  _blinkishPipeHangupFn = lib.lookupFunction<IshPipeHangupC, IshPipeHangupDart>(
    "blinkish_pipe_hangup",
  );
  _blinkishPipeDestroyFn = lib
      .lookupFunction<IshPipeDestroyC, IshPipeDestroyDart>(
        "blinkish_pipe_destroy",
      );
  _blinkishPipeExitCodeFn = lib
      .lookupFunction<IshPipeExitCodeC, IshPipeExitCodeDart>(
        "blinkish_pipe_exit_code",
      );
}

/// Whether the iSH bridge is linked into this build. Only iOS, where the
/// XCFramework from tool/ios/ish/build.sh is linked; false everywhere else,
/// so the FFI lookups are never made and the symbol is never touched.
bool get ishLinked => Platform.isIOS;

/// The resolved init function, or null where iSH is not linked. Called from the
/// background isolate.
IshInitDart? get ishInitFn {
  _resolve();
  return _initFn;
}

/// The resolved run-side functions, or null. Each is one step the worker's
/// own loop takes — drain, write the command, poll between chunks, read —
/// where the bridge's `ish_session_run` was one parked call for the whole
/// command; splitting it is what lets the command's output reach the run's
/// watch while it runs. Called from the background isolate.
IshDrainWakeDart? get ishDrainWakeFn {
  _resolve();
  return _drainWakeFn;
}

IshWriteStdinDart? get ishWriteStdinFn {
  _resolve();
  return _writeStdinFn;
}

IshPollDart? get ishPollFn {
  _resolve();
  return _pollFn;
}

IshReadDart? get ishReadFn {
  _resolve();
  return _readFn;
}

/// The resolved interrupt function, or null.
IshInterruptDart? get ishInterruptFn {
  _resolve();
  return _interruptFn;
}

/// The resolved hangup function, or null. Delivered from whatever isolate is
/// stopping a run — see [IshShell]'s interrupt path, which bypasses the
/// worker isolate so a stop does not queue behind the run it ends.
IshHangupDart? get ishHangupFn {
  _resolve();
  return _hangupFn;
}

/// The resolved destroy function, or null.
IshDestroyDart? get ishDestroyFn {
  _resolve();
  return _destroyFn;
}

/// The resolved fakefsify function, or null. Called to unpack a rootfs tarball
/// into iSH's fakefs layout in-process — the iOS analog of `tar -xzf`.
IshFakefsifyDart? get ishFakefsifyFn {
  _resolve();
  return _fakefsifyFn;
}

/// The blinkish (x86-64) core's twin entry points, or null. The same shape as
/// the iSH ones above, looked up by the `blinkish_*` names; both cores share
/// one fakefsify (the unpack is the same, whichever guest runs the rootfs), so
/// there is no blinkish fakefsify twin.
IshInitDart? get blinkishInitFn {
  _resolve();
  return _blinkishInitFn;
}

IshDrainWakeDart? get blinkishDrainWakeFn {
  _resolve();
  return _blinkishDrainWakeFn;
}

IshWriteStdinDart? get blinkishWriteStdinFn {
  _resolve();
  return _blinkishWriteStdinFn;
}

IshPollDart? get blinkishPollFn {
  _resolve();
  return _blinkishPollFn;
}

IshReadDart? get blinkishReadFn {
  _resolve();
  return _blinkishReadFn;
}

IshInterruptDart? get blinkishInterruptFn {
  _resolve();
  return _blinkishInterruptFn;
}

IshHangupDart? get blinkishHangupFn {
  _resolve();
  return _blinkishHangupFn;
}

IshDestroyDart? get blinkishDestroyFn {
  _resolve();
  return _blinkishDestroyFn;
}

/// The pipe-session entry points, or null where iSH is not linked. Same shape
/// as the session ones; called from the background isolate.
IshPipeInitDart? get ishPipeInitFn {
  _resolve();
  return _pipeInitFn;
}

IshPipeWriteDart? get ishPipeWriteFn {
  _resolve();
  return _pipeWriteFn;
}

IshPipeCloseInputDart? get ishPipeCloseInputFn {
  _resolve();
  return _pipeCloseInputFn;
}

IshPipePollDart? get ishPipePollFn {
  _resolve();
  return _pipePollFn;
}

IshPipeReadDart? get ishPipeReadFn {
  _resolve();
  return _pipeReadFn;
}

IshPipeTerminateDart? get ishPipeTerminateFn {
  _resolve();
  return _pipeTerminateFn;
}

IshPipeHangupDart? get ishPipeHangupFn {
  _resolve();
  return _pipeHangupFn;
}

IshPipeDestroyDart? get ishPipeDestroyFn {
  _resolve();
  return _pipeDestroyFn;
}

IshPipeExitCodeDart? get ishPipeExitCodeFn {
  _resolve();
  return _pipeExitCodeFn;
}

IshPipeInitDart? get blinkishPipeInitFn {
  _resolve();
  return _blinkishPipeInitFn;
}

IshPipeWriteDart? get blinkishPipeWriteFn {
  _resolve();
  return _blinkishPipeWriteFn;
}

IshPipeCloseInputDart? get blinkishPipeCloseInputFn {
  _resolve();
  return _blinkishPipeCloseInputFn;
}

IshPipePollDart? get blinkishPipePollFn {
  _resolve();
  return _blinkishPipePollFn;
}

IshPipeReadDart? get blinkishPipeReadFn {
  _resolve();
  return _blinkishPipeReadFn;
}

IshPipeTerminateDart? get blinkishPipeTerminateFn {
  _resolve();
  return _blinkishPipeTerminateFn;
}

IshPipeHangupDart? get blinkishPipeHangupFn {
  _resolve();
  return _blinkishPipeHangupFn;
}

IshPipeDestroyDart? get blinkishPipeDestroyFn {
  _resolve();
  return _blinkishPipeDestroyFn;
}

IshPipeExitCodeDart? get blinkishPipeExitCodeFn {
  _resolve();
  return _blinkishPipeExitCodeFn;
}
