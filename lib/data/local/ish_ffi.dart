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
typedef IshInitC = Pointer<Void> Function(
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
    Pointer<Pointer<Utf8>> error);
typedef IshInitDart = IshSessionPtr Function(
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
    Pointer<Pointer<Utf8>> error);

typedef IshDrainWakeC = Void Function(IshSessionPtr session);
typedef IshDrainWakeDart = void Function(IshSessionPtr session);

typedef IshWriteStdinC = Void Function(
    IshSessionPtr session, Pointer<Utf8> scriptB64);
typedef IshWriteStdinDart = void Function(
    IshSessionPtr session, Pointer<Utf8> scriptB64);

typedef IshPollC = Int32 Function(IshSessionPtr session);
typedef IshPollDart = int Function(IshSessionPtr session);

typedef IshReadC = Int32 Function(
    IshSessionPtr session, Pointer<Uint8> buf, Int32 cap);
typedef IshReadDart = int Function(
    IshSessionPtr session, Pointer<Uint8> buf, int cap);

typedef IshInterruptC = Void Function(IshSessionPtr session);
typedef IshInterruptDart = void Function(IshSessionPtr session);

typedef IshHangupC = Void Function(IshSessionPtr session);
typedef IshHangupDart = void Function(IshSessionPtr session);

typedef IshDestroyC = Void Function(IshSessionPtr session);
typedef IshDestroyDart = void Function(IshSessionPtr session);

typedef IshFakefsifyC = Int32 Function(Pointer<Utf8> archive, Pointer<Utf8> into);
typedef IshFakefsifyDart = int Function(Pointer<Utf8> archive, Pointer<Utf8> into);

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

bool _resolved = false;

void _resolve() {
  if (_resolved) return;
  _resolved = true;
  if (!ishLinked) return;
  final lib = DynamicLibrary.process();
  _initFn = lib.lookupFunction<IshInitC, IshInitDart>("ish_session_init");
  _drainWakeFn = lib.lookupFunction<IshDrainWakeC, IshDrainWakeDart>(
      "ish_session_drain_wake");
  _writeStdinFn = lib.lookupFunction<IshWriteStdinC, IshWriteStdinDart>(
      "ish_session_write_stdin");
  _pollFn = lib.lookupFunction<IshPollC, IshPollDart>("ish_session_poll");
  _readFn = lib.lookupFunction<IshReadC, IshReadDart>("ish_session_read");
  _interruptFn =
      lib.lookupFunction<IshInterruptC, IshInterruptDart>("ish_session_interrupt");
  _hangupFn =
      lib.lookupFunction<IshHangupC, IshHangupDart>("ish_session_hangup");
  _destroyFn =
      lib.lookupFunction<IshDestroyC, IshDestroyDart>("ish_session_destroy");
  _fakefsifyFn =
      lib.lookupFunction<IshFakefsifyC, IshFakefsifyDart>("ish_fakefsify");
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
