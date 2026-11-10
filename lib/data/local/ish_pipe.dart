import "dart:async";
import "dart:convert" show LineSplitter, utf8;
import "dart:ffi";
import "dart:isolate"
    show Isolate, ReceivePort, SendPort, TransferableTypedData;

import "package:ffi/ffi.dart";

import "../builtin/llm/providers/cli.dart"
    show CliGuest, CliProcess, LinuxCliGuest;
import "ish_ffi.dart";
import "ish_shell.dart" show IshWorker;

/// A [CliProcess] that runs a CLI program (`claude`, `codex`) inside the
/// iSH/blinkish guest as a long-lived interactive process, where iOS cannot
/// spawn a host child process. JSON lines written to stdin, read from stdout,
/// diagnostics on a separate stderr, and a real exit code the kernel's exit
/// hook reports.
///
/// The guest process lives on its own worker isolate, whose thread parks in the
/// bridge's poll between output chunks — the same parking that keeps
/// [IshWorker]'s command runs stoppable. Control that must land while that
/// thread is parked — [write], [closeInput], [kill] — goes straight to the
/// bridge from the calling isolate, the way [IshWorker]'s interrupt and hangup
/// do, rather than queueing behind the read loop.
class GuestCliProcess extends CliProcess {
  GuestCliProcess._({
    required this.handle,
    required this.worker,
    required this.stdout,
    required this.stderr,
    required Completer<int> exitCode,
  }) : _exitCode = exitCode; // ignore: prefer_initializing_formals

  /// Spawns [argv] (argv[0] the program, resolved through the guest's PATH) in
  /// the guest, with [env] its environment. [rootfsDir]/[dataDir]/[cwd] are
  /// the guest's, exactly as [IshWorker.init] takes them.
  /// [terminal] runs it on a terminal of the bridge's — one of iSH's own
  /// pseudo-terminals, [CliGuest.terminalColumns] by [CliGuest.terminalRows],
  /// read as stdout and typed into by [write] — where pipes would be.
  static Future<GuestCliProcess> start({
    required List<String> argv,
    required Map<String, String> env,
    required String rootfsDir,
    required String dataDir,
    required String cwd,
    bool terminal = false,
  }) async {
    final stdout = StreamController<List<int>>();
    final stderr = StreamController<List<int>>();
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
          (stream == 0 ? stdout : stderr).add(
            (msg[2] as TransferableTypedData).materialize().asUint8List(),
          );
        case _kExit:
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

    // The pipe's init boots and binds the guest as a shell session's does,
    // so it takes its turn in the same order.
    final address = await IshWorker.serialised(() async {
      await Isolate.spawn(_pipeEntry, (
        replies.sendPort,
        rootfsDir,
        dataDir,
        cwd,
        argv,
        [for (final e in env.entries) "${e.key}=${e.value}"],
        terminal,
      ), onExit: exitPort.sendPort);
      return handle.future;
    });

    final process = GuestCliProcess._(
      handle: address,
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

  /// The worker isolate's port. [destroy] is the one message that still needs
  /// it; the pokes below reach the bridge directly.
  final SendPort worker;

  final StreamController<List<int>> stdout;
  final StreamController<List<int>> stderr;
  final Completer<int> _exitCode;

  bool _closed = false;

  @override
  Stream<String> get lines =>
      stdout.stream.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<String> get errors => stderr.stream.transform(utf8.decoder);

  @override
  void write(String text) {
    if (_closed) return;
    final fn = _core.bridge?.pipeWrite;
    if (fn == null) return;
    // The byte length, not the character count: a non-ASCII line has more
    // bytes than code units, and a character count truncates the write.
    final bytes = utf8.encode(text);
    final ptr = calloc<Uint8>(bytes.length);
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    fn(Pointer.fromAddress(handle), ptr.cast(), bytes.length);
    calloc.free(ptr);
  }

  @override
  Future<void> closeInput() async {
    if (_closed) return;
    _core.bridge?.pipeCloseInput(Pointer.fromAddress(handle));
  }

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void kill({bool force = false}) {
    final bridge = _core.bridge;
    if (bridge == null) return;
    (force ? bridge.pipeHangup : bridge.pipeTerminate)(
      Pointer.fromAddress(handle),
    );
  }

  /// Ends the worker isolate and frees the guest process, once the process is
  /// gone. Called by the session's close path.
  void destroy() {
    if (_closed) return;
    _closed = true;
    _core.bridge?.pipeDestroy(Pointer.fromAddress(handle));
    worker.send(const [_kStop]);
  }
}

/// iOS's Linux as where a CLI's program runs: the x86-64 guest in the
/// emulator, over the rootfs the Terminal settings picked, looked up at each
/// start. The app data directory is mounted at its host path, so the
/// program's cache and work folders are the same paths to Dart and to the
/// guest, and the shared folders need no binding of their own.
class IshCliGuest extends LinuxCliGuest {
  IshCliGuest({required this.rootfsDir, required this.dataDir});

  /// The picked Linux's directory, or null where none is installed.
  final String? Function() rootfsDir;
  final String dataDir;

  /// The emulator's, not the device's: the programs are x86-64 Linux
  /// builds.
  @override
  Abi get abi => Abi.linuxX64;

  @override
  Future<CliProcess> spawn(
    List<String> argv, {
    required String cwd,
    required Map<String, String> environment,
    required List<String> shared,
    required bool terminal,
  }) {
    return GuestCliProcess.start(
      argv: terminal ? LinuxCliGuest.withBrowser(argv) : argv,
      env: environment,
      rootfsDir: LinuxCliGuest.installed(rootfsDir()),
      dataDir: dataDir,
      cwd: cwd,
      terminal: terminal,
    );
  }
}

/// The core a CLI program runs on: the x86-64 one, since the programs' builds
/// are x86-64 Linux ones and the i386 core cannot run them.
const _core = IshCore.x86_64;

// Message tags between the main isolate and the pipe worker.
const _kReply = 0;
const _kOutput = 1;
const _kExit = 2;
const _kStop = 3;

/// The worker isolate's entry point: resolve the pipe entry points, spawn the
/// guest process, stream its output, and report its exit code. Writes and
/// signals reach the process from the calling isolate (the pokes), not here.
void _pipeEntry(
  (SendPort, String, String, String, List<String>, List<String>, bool) arg,
) {
  final (main, rootfsDir, dataDir, cwd, argv, env, terminal) = arg;
  final receive = ReceivePort();
  main.send(receive.sendPort);

  final bridge = _core.bridge;
  if (bridge == null) {
    main.send(const [_kReply, "iSH is not linked", null]);
    return;
  }

  final (handle, error) = using((arena) {
    final errPtr = arena<Pointer<Utf8>>();
    final handle = bridge.pipeInit(
      rootfsDir.toNativeUtf8(allocator: arena),
      dataDir.toNativeUtf8(allocator: arena),
      cwd.toNativeUtf8(allocator: arena),
      cStrings(argv, arena),
      argv.length,
      cStrings(env, arena),
      env.length,
      terminal ? CliGuest.terminalColumns : 0,
      terminal ? CliGuest.terminalRows : 0,
      errPtr,
    );
    final error = errPtr.value.address == 0
        ? null
        : errPtr.value.cast<Utf8>().toDartString();
    return (handle, error);
  });

  if (error != null || handle.address == 0) {
    main.send([_kReply, error ?? "the program failed to start", null]);
    return;
  }
  main.send([_kReply, null, handle.address]);

  // The read loop: park on the bridge's poll, stream stdout and stderr chunks,
  // and end only on the wake byte the exit hook (or a hangup) drops. The exit
  // code is the hook's atomic, read after the byte announces it. A stream that
  // reaches EOF is dropped by the poll, never treated as the end of the process:
  // do_exit closes the fds before the hook runs, so EOF precedes the exit code.
  final buf = calloc<Uint8>(65536);
  // One read of a stream, sent on if it held anything. The bridge's ends are
  // non-blocking, so an empty stream answers at once rather than parking.
  bool forward(int stream) {
    final n = bridge.pipeRead(handle, stream, buf, 65536);
    if (n <= 0) return false;
    main.send([
      _kOutput,
      stream,
      TransferableTypedData.fromList([buf.asTypedList(n)]),
    ]);
    return true;
  }

  try {
    while (true) {
      final flags = bridge.pipePoll(handle);
      if (flags < 0) break;
      if (flags & 4 != 0) {
        // The wake byte: exit, or a hangup. The program's last words may
        // still be in the pipes, so take them before the exit code.
        while (forward(0)) {}
        while (forward(1)) {}
        break;
      }
      if (flags & 1 != 0) forward(0);
      if (flags & 2 != 0) forward(1);
    }
  } finally {
    calloc.free(buf);
  }
  main.send([_kExit, bridge.pipeExitCode(handle)]);

  // The process is gone; the isolate has nothing left but a stop or destroy.
  receive.listen((msg) {
    if (msg is List && msg.isNotEmpty && msg[0] == _kStop) {
      Isolate.exit();
    }
  });
}
