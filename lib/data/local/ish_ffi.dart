import "dart:ffi";
import "dart:io" show Platform;

// Utf8 moved out of dart:ffi; package:ffi's is the one Dart 3.13 keeps.
import "package:ffi/ffi.dart";

import "../../domain/shell.dart";
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

// The result struct the bridge writes into. Matches ish_bridge.h's ish_result,
// which is naturally aligned (int, then three pointers) — the C side has no
// #pragma pack, so neither does this. Packing it would move every pointer
// field and read garbage into the strings.
final class IshResult extends Struct {
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
typedef IshInitC = Pointer<Void> Function(
    Pointer<Utf8> rootfsDir,
    Pointer<Utf8> dataDir,
    Pointer<Utf8> home,
    Pointer<Utf8> cwd,
    Pointer<Utf8> dispatcher,
    Pointer<Utf8> token,
    Pointer<Pointer<Utf8>> env,
    Int32 envCount,
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
    Pointer<Pointer<Utf8>> error);

typedef IshRunC = Void Function(
    IshSessionPtr session,
    Pointer<Utf8> scriptB64,
    Int32 timeoutMs,
    Pointer<IshResult> out);
typedef IshRunDart = void Function(
    IshSessionPtr session,
    Pointer<Utf8> scriptB64,
    int timeoutMs,
    Pointer<IshResult> out);

typedef IshInterruptC = Void Function(IshSessionPtr session);
typedef IshInterruptDart = void Function(IshSessionPtr session);

typedef IshDestroyC = Void Function(IshSessionPtr session);
typedef IshDestroyDart = void Function(IshSessionPtr session);

typedef IshFakefsifyC = Int32 Function(Pointer<Utf8> archive, Pointer<Utf8> into);
typedef IshFakefsifyDart = int Function(Pointer<Utf8> archive, Pointer<Utf8> into);

// The lazy lookups. Null until first use, and only ever resolved on iOS.
IshInitDart? _initFn;
IshRunDart? _runFn;
IshInterruptDart? _interruptFn;
IshDestroyDart? _destroyFn;
IshFakefsifyDart? _fakefsifyFn;

bool _resolved = false;

void _resolve() {
  if (_resolved) return;
  _resolved = true;
  if (!ishLinked) return;
  final lib = DynamicLibrary.process();
  _initFn = lib.lookupFunction<IshInitC, IshInitDart>("ish_session_init");
  _runFn = lib.lookupFunction<IshRunC, IshRunDart>("ish_session_run");
  _interruptFn =
      lib.lookupFunction<IshInterruptC, IshInterruptDart>("ish_session_interrupt");
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

/// The resolved run function, or null.
IshRunDart? get ishRunFn {
  _resolve();
  return _runFn;
}

/// The resolved interrupt function, or null.
IshInterruptDart? get ishInterruptFn {
  _resolve();
  return _interruptFn;
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
