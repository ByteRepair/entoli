import "dart:async";
import "dart:convert" show LineSplitter, utf8;
import "dart:ffi";
import "dart:isolate" show Isolate, ReceivePort, SendPort;
import "dart:typed_data" show Uint8List;

import "package:ffi/ffi.dart";
import "package:flutter/foundation.dart" show debugPrint;

import "../../domain/shell.dart" show guestPath;
import "../builtin/llm/llm_client.dart" show LlmException;
import "../builtin/llm/providers/cli.dart"
    show CliGuest, CliProcess, CliProcessLauncher, LaunchCli;
import "ish_ffi.dart";

/// A [CliProcess] that runs a CLI program (`claude`, `codex`) inside the
/// iSH/blinkish guest as a long-lived interactive process, where iOS cannot
/// spawn a host child process. JSON lines written to stdin, read from stdout,
/// diagnostics on a separate stderr, and a real exit code the kernel's exit
/// hook reports.
///
/// The guest process lives on its own worker isolate, whose thread parks in the
/// bridge's poll between output chunks — the same parking that keeps
/// [IshWorker]'s command runs stoppable. Control that must land while that
/// thread is parked — [writeLine], [closeInput], [kill] — goes straight to the
/// bridge from the calling isolate, the way [IshWorker]'s interrupt and hangup
/// do, rather than queueing behind the read loop.
class GuestCliProcess implements CliProcess {
  GuestCliProcess._({
    required this.handle,
    required this.blinkish,
    required this.worker,
    required this.stdout,
    required this.stderr,
    required Completer<int> exitCode,
  }) : _exitCode = exitCode; // ignore: prefer_initializing_formals

  /// Spawns [argv] (argv[0] the program, resolved through the guest's PATH) in
  /// the guest, with [env] its environment. [rootfsDir]/[dataDir]/[home]/
  /// [cwd]/[readOnly] are the guest's, exactly as [IshWorker.init] takes them.
  /// [blinkish] picks the x86-64 core (true) or the i386 one (false).
  static Future<GuestCliProcess> start({
    required List<String> argv,
    required Map<String, String> env,
    required String rootfsDir,
    required String dataDir,
    required String home,
    required String cwd,
    List<String> readOnly = const [],
    bool blinkish = true,
  }) async {
    final stdout = StreamController<String>();
    final stderr = StreamController<String>();
    final exitCode = Completer<int>();

    final replies = ReceivePort();
    final exitPort = ReceivePort();
    final handle = Completer<int>();
    SendPort? sendPort;
    late final StreamSubscription<dynamic> sub;

    sub = replies.listen((msg) {
      if (msg is SendPort) {
        sendPort = msg;
        return;
      }
      if (msg is! List) return;
      switch (msg[0] as int) {
        case _kReply:
          final error = msg[1] as String?;
          if (error != null) {
            handle.completeError(StateError(error));
          } else {
            handle.complete(msg[2] as int);
          }
        case _kOutput:
          final stream = msg[1] as int;
          final delta = utf8.decode(msg[2] as Uint8List, allowMalformed: true);
          (stream == 0 ? stdout : stderr).add(delta);
        case _kExit:
          debugPrint("[ish-pipe] main got exit ${msg[1] as int}");
          if (!exitCode.isCompleted) exitCode.complete(msg[1] as int);
          unawaited(sub.cancel());
          exitPort.close();
          replies.close();
      }
    });
    exitPort.listen((_) {
      if (!handle.isCompleted) {
        handle.completeError(StateError("The iSH pipe driver stopped."));
      }
      if (!exitCode.isCompleted) exitCode.complete(-1);
      unawaited(sub.cancel());
      replies.close();
    });

    await Isolate.spawn(_pipeEntry, (
      replies.sendPort,
      blinkish,
      rootfsDir,
      dataDir,
      home,
      cwd,
      argv,
      [for (final e in env.entries) "${e.key}=${e.value}"],
      readOnly,
    ), onExit: exitPort.sendPort);

    final address = await handle.future;

    final process = GuestCliProcess._(
      handle: address,
      blinkish: blinkish,
      worker: sendPort!,
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
    );
    // The interface has no close(): once the process is gone, the worker
    // isolate and the C session must still be torn down, so destroy rides the
    // exit rather than a caller that will not come.
    unawaited(exitCode.future.then((_) => process.destroy()));
    return process;
  }

  /// The pipe session's C handle address, for the pokes that bypass the worker.
  final int handle;

  /// Whether this drives the blinkish (x86-64) bridge or the i386 one.
  final bool blinkish;

  /// The worker isolate's port. [destroy] is the one message that still needs
  /// it; the pokes below reach the bridge directly.
  final SendPort worker;

  final StreamController<String> stdout;
  final StreamController<String> stderr;
  final Completer<int> _exitCode;

  bool _closed = false;

  @override
  Stream<String> get lines => stdout.stream.transform(const LineSplitter());

  @override
  Stream<String> get errors => stderr.stream;

  @override
  void writeLine(String line) {
    if (_closed) return;
    final fn = blinkish ? blinkishPipeWriteFn : ishPipeWriteFn;
    if (fn == null) return;
    final text = "$line\n";
    final ptr = text.toNativeUtf8();
    fn(Pointer.fromAddress(handle), ptr, text.length);
    calloc.free(ptr);
  }

  @override
  Future<void> closeInput() async {
    if (_closed) return;
    final fn = blinkish ? blinkishPipeCloseInputFn : ishPipeCloseInputFn;
    fn?.call(Pointer.fromAddress(handle));
  }

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void kill({bool force = false}) {
    final fn = force
        ? (blinkish ? blinkishPipeHangupFn : ishPipeHangupFn)
        : (blinkish ? blinkishPipeTerminateFn : ishPipeTerminateFn);
    fn?.call(Pointer.fromAddress(handle));
  }

  /// Ends the worker isolate and frees the guest process, once the process is
  /// gone. Called by the session's close path.
  void destroy() {
    if (_closed) return;
    _closed = true;
    final fn = blinkish ? blinkishPipeDestroyFn : ishPipeDestroyFn;
    fn?.call(Pointer.fromAddress(handle));
    worker.send(const [_kStop]);
  }
}

/// iOS's in-process Linux for the CLI provider's common guest contract. The
/// app data directory is mounted at its host path, so the provider's cache and
/// working directory remain visible to both Dart and the guest.
class IshCliGuest implements CliGuest, CliProcessLauncher {
  IshCliGuest({required this.rootfsDir, required this.dataDir});

  final String Function() rootfsDir;
  final String dataDir;

  @override
  ({List<String> command, Map<String, String> environment}) wrap(
    List<String> argv, {
    required String cwd,
    required List<String> shared,
  }) => (command: argv, environment: const {});

  @override
  List<String> install(List<String> packages) => [
    "apk",
    "add",
    "--no-cache",
    ...packages,
  ];

  @override
  LaunchCli get processLauncher =>
      (
        String executable,
        List<String> arguments, {
        required String workingDirectory,
        required Map<String, String> environment,
      }) {
        final rootfs = rootfsDir();
        if (rootfs.isEmpty) {
          throw LlmException(
            "No Linux is installed to run it in. Install one from the "
            "Terminal settings.",
          );
        }
        return GuestCliProcess.start(
          argv: [executable, ...arguments],
          env: {...environment, "PATH": guestPath},
          rootfsDir: rootfs,
          dataDir: dataDir,
          home: "",
          cwd: workingDirectory,
          readOnly: const [],
          blinkish: true,
        );
      };
}

// Message tags between the main isolate and the pipe worker.
const _kReply = 0;
const _kOutput = 1;
const _kExit = 2;
const _kStop = 3;

/// The worker isolate's entry point: resolve the pipe entry points, spawn the
/// guest process, stream its output, and report its exit code. Writes and
/// signals reach the process from the calling isolate (the pokes), not here.
void _pipeEntry(
  (
    SendPort,
    bool,
    String,
    String,
    String,
    String,
    List<String>,
    List<String>,
    List<String>,
  )
  arg,
) {
  final (main, blinkish, rootfsDir, dataDir, home, cwd, argv, env, readOnly) =
      arg;
  final receive = ReceivePort();
  main.send(receive.sendPort);

  final initFn = blinkish ? blinkishPipeInitFn : ishPipeInitFn;
  final pollFn = blinkish ? blinkishPipePollFn : ishPipePollFn;
  final readFn = blinkish ? blinkishPipeReadFn : ishPipeReadFn;
  final exitCodeFn = blinkish ? blinkishPipeExitCodeFn : ishPipeExitCodeFn;

  if (initFn == null ||
      pollFn == null ||
      readFn == null ||
      exitCodeFn == null) {
    main.send(const [_kReply, "iSH is not linked", null]);
    return;
  }

  final argvPtrs = calloc<Pointer<Utf8>>(argv.length);
  for (var i = 0; i < argv.length; i++) {
    argvPtrs[i] = argv[i].toNativeUtf8();
  }
  final envPtrs = calloc<Pointer<Utf8>>(env.length);
  for (var i = 0; i < env.length; i++) {
    envPtrs[i] = env[i].toNativeUtf8();
  }
  final readOnlyPtrs = calloc<Pointer<Utf8>>(readOnly.length);
  for (var i = 0; i < readOnly.length; i++) {
    readOnlyPtrs[i] = readOnly[i].toNativeUtf8();
  }
  final rootfsPtr = rootfsDir.toNativeUtf8();
  final dataPtr = dataDir.toNativeUtf8();
  final homePtr = home.toNativeUtf8();
  final cwdPtr = cwd.toNativeUtf8();
  final errPtr = calloc<Pointer<Utf8>>();

  final handle = initFn(
    rootfsPtr,
    dataPtr,
    homePtr,
    cwdPtr,
    argvPtrs,
    argv.length,
    envPtrs,
    env.length,
    readOnlyPtrs,
    readOnly.length,
    errPtr,
  );
  final error = errPtr.value.address == 0
      ? null
      : errPtr.value.cast<Utf8>().toDartString();

  calloc.free(rootfsPtr);
  calloc.free(dataPtr);
  calloc.free(homePtr);
  calloc.free(cwdPtr);
  for (var i = 0; i < argv.length; i++) {
    calloc.free(argvPtrs[i]);
  }
  calloc.free(argvPtrs);
  for (var i = 0; i < env.length; i++) {
    calloc.free(envPtrs[i]);
  }
  calloc.free(envPtrs);
  for (var i = 0; i < readOnly.length; i++) {
    calloc.free(readOnlyPtrs[i]);
  }
  calloc.free(readOnlyPtrs);
  calloc.free(errPtr);

  if (error != null || handle.address == 0) {
    main.send([_kReply, error ?? "the program failed to start", null]);
    return;
  }
  main.send([_kReply, null, handle.address]);

  // The read loop: park on the bridge's poll, stream stdout and stderr chunks,
  // and end on the wake byte the exit hook (or a hangup) drops. The exit code
  // is the hook's atomic, read after the byte announces it.
  final buf = calloc<Uint8>(65536);
  var ended = "?";
  try {
    while (true) {
      final flags = pollFn(handle);
      if (flags < 0) {
        ended = "poll<0";
        break;
      }
      if (flags & 4 != 0) {
        ended = "wake";
        break; // the wake byte: exit, or a hangup
      }
      if (flags & 1 != 0) {
        final n = readFn(handle, 0, buf, 65536);
        if (n > 0) {
          main.send([_kOutput, 0, Uint8List.fromList(buf.asTypedList(n))]);
        } else if (n == 0) {
          ended = "stdout-eof";
          break;
        } else if (n == -2) {
          continue;
        } else {
          ended = "stdout-read<$n";
          break;
        }
      }
      if (flags & 2 != 0) {
        final n = readFn(handle, 1, buf, 65536);
        if (n > 0) {
          main.send([_kOutput, 1, Uint8List.fromList(buf.asTypedList(n))]);
        } else if (n == 0) {
          ended = "stderr-eof";
          break;
        } else if (n == -2) {
          continue;
        } else {
          ended = "stderr-read<$n";
          break;
        }
      }
    }
  } finally {
    calloc.free(buf);
  }
  final code = exitCodeFn(handle);
  main.send([_kExit, code]);
  debugPrint("[ish-pipe] worker loop ended via $ended, exitCode=$code");

  // The process is gone; the isolate has nothing left but a stop or destroy.
  receive.listen((msg) {
    if (msg is List && msg.isNotEmpty && msg[0] == _kStop) {
      Isolate.exit();
    }
  });
}
