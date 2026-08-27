import "dart:ffi";
import "dart:io" show Platform;

import "package:ffi/ffi.dart";

import "../../domain/shell.dart";
// The dart:ffi bindings to the iSH bridge (tool/bundle/ish/ish_bridge.c). The
// bridge runs the iSH emulator core in-process — see ios/CLAUDE.md for why a
// child-process shell cannot work on iOS.
//
// The symbols are linked into the app executable (a static lib, not a dylib),
// so they are looked up through DynamicLibrary.process() — once, on first use,
// and only on iOS. Everywhere else ishLinked is false and nothing below is ever
// called, so the symbol is never looked up and the build carries no iSH.

// The opaque pointer Dart holds for a session.
typedef ish_session_ptr = Pointer<Void>;

// C callback signature: void(ish_result*, void*).
typedef _ish_result_callback_c = Void Function(
    Pointer<ish_result> result, Pointer<Void> userData);

// The result struct the bridge posts back. Matches ish_bridge.h's ish_result.
@Packed(4)
final class ish_result extends Struct {
  @Int32()
  external int returnCode;

  external Pointer<Utf8> output;

  external Pointer<Utf8> cwd;

  external Pointer<Utf8> exception;

  ShellResult toShellResult() {
    final out = output.address == 0 ? "" : output.cast<Utf8>().toDartString();
    final cwdStr = cwd.address == 0 ? null : cwd.cast<Utf8>().toDartString();
    final exc = exception.address == 0 ? null : exception.cast<Utf8>().toDartString();
    if (exc != null && returnCode == -1) {
      return ShellResult.failed(exc, output: out);
    }
    return ShellResult(returnCode: returnCode, output: out, cwd: cwdStr);
  }
}

// Function pointer types for the four bridge entry points.
typedef _init_c = Pointer<Void> Function(
    Pointer<Utf8> rootfsDir,
    Pointer<Utf8> dataDir,
    Pointer<Utf8> home,
    Pointer<Pointer<Utf8>> env,
    Int32 envCount,
    Pointer<Pointer<Utf8>> error);
typedef _init_dart = ish_session_ptr Function(
    Pointer<Utf8> rootfsDir,
    Pointer<Utf8> dataDir,
    Pointer<Utf8> home,
    Pointer<Pointer<Utf8>> env,
    int envCount,
    Pointer<Pointer<Utf8>> error);

typedef _run_c = Void Function(
    ish_session_ptr session,
    Pointer<Utf8> scriptB64,
    Int32 timeoutMs,
    Pointer<NativeFunction<_ish_result_callback_c>> callback,
    Pointer<Void> userData);
typedef _run_dart = void Function(
    ish_session_ptr session,
    Pointer<Utf8> scriptB64,
    int timeoutMs,
    Pointer<NativeFunction<_ish_result_callback_c>> callback,
    Pointer<Void> userData);

typedef _interrupt_c = Void Function(ish_session_ptr session);
typedef _interrupt_dart = void Function(ish_session_ptr session);

typedef _destroy_c = Void Function(ish_session_ptr session);
typedef _destroy_dart = void Function(ish_session_ptr session);

// The lazy lookups. Null until first use, and only ever resolved on iOS.
_init_dart? _initFn;
_run_dart? _runFn;
_interrupt_dart? _interruptFn;
_destroy_dart? _destroyFn;

bool _resolved = false;

void _resolve() {
  if (_resolved) return;
  _resolved = true;
  if (!ishLinked) return;
  final lib = DynamicLibrary.process();
  _initFn = lib.lookupFunction<_init_c, _init_dart>("ish_session_init");
  _runFn = lib.lookupFunction<_run_c, _run_dart>("ish_session_run");
  _interruptFn =
      lib.lookupFunction<_interrupt_c, _interrupt_dart>("ish_session_interrupt");
  _destroyFn =
      lib.lookupFunction<_destroy_c, _destroy_dart>("ish_session_destroy");
}

/// Whether the iSH bridge is linked into this build. Only iOS, where the
/// XCFramework from tool/bundle/ish/build.sh is linked; false everywhere else,
/// so the FFI lookups are never made and the symbol is never touched.
bool get ishLinked => Platform.isIOS;

/// The resolved init function, or null where iSH is not linked. Called from the
/// background isolate.
_init_dart? get ishInitFn {
  _resolve();
  return _initFn;
}

/// The resolved run function, or null.
_run_dart? get ishRunFn {
  _resolve();
  return _runFn;
}

/// The resolved interrupt function, or null.
_interrupt_dart? get ishInterruptFn {
  _resolve();
  return _interruptFn;
}

/// The resolved destroy function, or null.
_destroy_dart? get ishDestroyFn {
  _resolve();
  return _destroyFn;
}
