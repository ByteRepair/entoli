import "dart:ffi";
import "dart:io" show Platform;

// Utf8 moved out of dart:ffi; package:ffi's is the one Dart 3.13 keeps.
import "package:ffi/ffi.dart";

import "../../domain/rootfs.dart" show EmulatedLinux, Rootfs;

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

typedef IshSetHostCallsC = Void Function(Pointer<Utf8> hostDir);
typedef IshSetHostCallsDart = void Function(Pointer<Utf8> hostDir);

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
      Pointer<Utf8> cwd,
      Pointer<Pointer<Utf8>> argv,
      Int32 argc,
      Pointer<Pointer<Utf8>> env,
      Int32 envCount,
      Int32 terminalCols,
      Int32 terminalRows,
      Pointer<Pointer<Utf8>> error,
    );
typedef IshPipeInitDart =
    IshPipeSessionPtr Function(
      Pointer<Utf8> rootfsDir,
      Pointer<Utf8> dataDir,
      Pointer<Utf8> cwd,
      Pointer<Pointer<Utf8>> argv,
      int argc,
      Pointer<Pointer<Utf8>> env,
      int envCount,
      int terminalCols,
      int terminalRows,
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

/// Whether the iSH bridge is linked into this build. Only iOS, where the
/// XCFramework from tool/ios/ish/build.sh is linked; false everywhere else,
/// so the FFI lookups are never made and the symbol is never touched.
bool get ishLinked => Platform.isIOS;

/// The two emulator cores the bridge links. Each exports the same entry
/// points under its own prefix — `ish_session_init`, `blinkish_session_init`
/// — and a session or a guest program is driven through one of them for its
/// whole life.
enum IshCore {
  /// The i386 guest, on iSH's own asbestos.
  i386("ish"),

  /// The x86-64 guest, on blink's interpreter: blinkish.
  x86_64("blinkish");

  const IshCore(this.prefix);

  /// What the core's entry points are named with.
  final String prefix;

  /// The core's entry points, or null where the bridge is not linked. Looked
  /// up on first use in each isolate, since a function looked up on one is
  /// not valid on another.
  IshBridge? get bridge =>
      ishLinked ? _bridges[this] ??= IshBridge._(this) : null;
}

final _bridges = <IshCore, IshBridge>{};

/// The core that runs [rootfs]: the one its iOS image is built for, the x86-64
/// one for an x86_64 image and iSH's own asbestos for anything else — an i386
/// Alpine kept from before the catalog went x86-64.
IshCore ishCoreOf(Rootfs? rootfs) =>
    rootfs?.images[EmulatedLinux.key]?.arch == "x86_64"
    ? IshCore.x86_64
    : IshCore.i386;

/// One core's entry points. The session ones run the shell's commands, a
/// step at a time — drain, write the command, poll between chunks, read —
/// so a command's output reaches the run's watch while it runs; the pipe
/// ones run a guest program directly, for the CLI providers. Interrupt,
/// hangup and the pipe's write, close, terminate and hangup are delivered
/// from whatever isolate is stopping or feeding a run, so they do not queue
/// behind the run they act on.
class IshBridge {
  IshBridge._(IshCore core)
    : this._lookup(DynamicLibrary.process(), core.prefix);

  IshBridge._lookup(DynamicLibrary lib, String prefix)
    : init = lib.lookupFunction<IshInitC, IshInitDart>(
        "${prefix}_session_init",
      ),
      drainWake = lib.lookupFunction<IshDrainWakeC, IshDrainWakeDart>(
        "${prefix}_session_drain_wake",
      ),
      writeStdin = lib.lookupFunction<IshWriteStdinC, IshWriteStdinDart>(
        "${prefix}_session_write_stdin",
      ),
      poll = lib.lookupFunction<IshPollC, IshPollDart>(
        "${prefix}_session_poll",
      ),
      read = lib.lookupFunction<IshReadC, IshReadDart>(
        "${prefix}_session_read",
      ),
      interrupt = lib.lookupFunction<IshInterruptC, IshInterruptDart>(
        "${prefix}_session_interrupt",
      ),
      hangup = lib.lookupFunction<IshHangupC, IshHangupDart>(
        "${prefix}_session_hangup",
      ),
      destroy = lib.lookupFunction<IshDestroyC, IshDestroyDart>(
        "${prefix}_session_destroy",
      ),
      pipeInit = lib.lookupFunction<IshPipeInitC, IshPipeInitDart>(
        "${prefix}_pipe_init",
      ),
      pipeWrite = lib.lookupFunction<IshPipeWriteC, IshPipeWriteDart>(
        "${prefix}_pipe_write",
      ),
      pipeCloseInput = lib
          .lookupFunction<IshPipeCloseInputC, IshPipeCloseInputDart>(
            "${prefix}_pipe_close_input",
          ),
      pipePoll = lib.lookupFunction<IshPipePollC, IshPipePollDart>(
        "${prefix}_pipe_poll",
      ),
      pipeRead = lib.lookupFunction<IshPipeReadC, IshPipeReadDart>(
        "${prefix}_pipe_read",
      ),
      pipeTerminate = lib
          .lookupFunction<IshPipeTerminateC, IshPipeTerminateDart>(
            "${prefix}_pipe_terminate",
          ),
      pipeHangup = lib.lookupFunction<IshPipeHangupC, IshPipeHangupDart>(
        "${prefix}_pipe_hangup",
      ),
      pipeDestroy = lib.lookupFunction<IshPipeDestroyC, IshPipeDestroyDart>(
        "${prefix}_pipe_destroy",
      ),
      pipeExitCode = lib.lookupFunction<IshPipeExitCodeC, IshPipeExitCodeDart>(
        "${prefix}_pipe_exit_code",
      ),
      setHostCalls = lib.lookupFunction<IshSetHostCallsC, IshSetHostCallsDart>(
        "${prefix}_set_host_calls",
      );

  final IshInitDart init;
  final IshDrainWakeDart drainWake;
  final IshWriteStdinDart writeStdin;
  final IshPollDart poll;
  final IshReadDart read;
  final IshInterruptDart interrupt;
  final IshHangupDart hangup;
  final IshDestroyDart destroy;

  final IshPipeInitDart pipeInit;
  final IshPipeWriteDart pipeWrite;
  final IshPipeCloseInputDart pipeCloseInput;
  final IshPipePollDart pipePoll;
  final IshPipeReadDart pipeRead;
  final IshPipeTerminateDart pipeTerminate;
  final IshPipeHangupDart pipeHangup;
  final IshPipeDestroyDart pipeDestroy;
  final IshPipeExitCodeDart pipeExitCode;

  /// Names the host directory the guest binds at /run/entoli; see
  /// [HostTools].
  final IshSetHostCallsDart setHostCalls;
}

/// [strings] as a C array of C strings, both allocated in [arena], which
/// frees them when the call they were made for is over. The bridge copies
/// whatever it keeps.
Pointer<Pointer<Utf8>> cStrings(List<String> strings, Arena arena) {
  final array = arena<Pointer<Utf8>>(strings.length);
  for (var i = 0; i < strings.length; i++) {
    array[i] = strings[i].toNativeUtf8(allocator: arena);
  }
  return array;
}

IshFakefsifyDart? _fakefsifyFn;

/// The bridge's fakefsify, or null where it is not linked: a rootfs tarball
/// unpacked into iSH's fakefs layout in-process, the iOS analog of
/// `tar -xzf`. One for both cores, since the unpack is the same whichever
/// guest runs the rootfs.
IshFakefsifyDart? get ishFakefsifyFn {
  if (!ishLinked) return null;
  return _fakefsifyFn ??= DynamicLibrary.process()
      .lookupFunction<IshFakefsifyC, IshFakefsifyDart>("ish_fakefsify");
}
