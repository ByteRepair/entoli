import "dart:async";
import "dart:convert";
import "dart:ffi";
import "dart:isolate" show Isolate, ReceivePort, SendPort;

import "package:ffi/ffi.dart";
import "package:flutter/foundation.dart" show ValueListenable, ValueNotifier;

import "../../domain/shell.dart";
import "ish_ffi.dart";

/// The iOS shell. iOS denies an app a child process, so the host shell every
/// other platform has — one that does `Process.start` of `/bin/sh` or a bundled
/// `proot` — cannot work here. iSH runs the whole guest in-process, and this
/// is the `Shell` that drives it through the FFI bridge
/// (`tool/bundle/ish/ish_bridge.c`). See ios/CLAUDE.md.
///
/// It does not extend `LocalShell`: `LocalShell`'s persistent session is a
/// single child process whose stdin is fed base64 lines and whose stdout is
/// read for a marker, and iOS has no child process to be. This carries its own
/// session map, each entry an iSH handle driven through `ish_ffi.dart` on a
/// long-lived background isolate, so a guest command does not block the UI.
///
/// The dispatcher script (`dispatcherScript` in `domain/shell.dart`) is shared
/// with `LocalShell`: it runs inside the guest's own `/bin/sh`, so a `cd` or an
/// `export` in one emulated command sticks for the next, the same contract the
/// host shell keeps. The marker the guest writes back is parsed for the exit
/// code and the directory the shell is now in, the same way `LocalShell._Session`
/// parses its child process's output.
class IshShell extends Shell {
  IshShell({
    required this.rootfsDir,
    required this.dataDir,
    required Map<String, String> Function() environment,
    required this.platformDescription,
  }) : _environment = environment;

  final String rootfsDir;
  final String dataDir;

  @override
  final String platformDescription;

  final Map<String, String> Function() _environment;

  final Map<String, _IshSession> _sessions = {};
  final Map<String, ValueNotifier<String?>> _cwds = {};

  @override
  bool get canRunCommands => true;

  @override
  bool get projectHome => true;

  @override
  ShellRun start(String command,
      {required String cwd,
      required String home,
      required Duration timeout,
      Map<String, String>? environment,
      bool sharedHome = true,
      bool oneShot = false,
      bool restart = false}) {
    if (oneShot) {
      return _IshOneShotRun(
        rootfsDir: rootfsDir,
        dataDir: dataDir,
        home: home,
        script: command,
        cwd: cwd,
        timeout: timeout,
        environment: _compose(home: home, environment: environment),
      );
    }
    return _sessions
        .putIfAbsent(cwd, () => _IshSession(this, cwd, home))
        .start(command, timeout, environment: environment, restart: restart);
  }

  @override
  ValueListenable<String?>? sessionCwd(String cwd) =>
      _cwds.putIfAbsent(cwd, () => ValueNotifier<String?>(cwd));

  @override
  void closeSession(String cwd) {
    _cwds.remove(cwd)?.dispose();
    _sessions.remove(cwd)?.close();
  }

  Map<String, String> _compose({
    required String home,
    Map<String, String>? environment,
  }) =>
      {
        "HOME": home,
        ..._environment(),
        ...?environment,
      };
}

class _IshSession {
  _IshSession(this._shell, this._cwdPath, this._home);

  final IshShell _shell;
  final String _cwdPath;
  final String _home;

  int? _sessionId;
  bool _dead = true;
  Future<void> _queue = Future.value();
  _IshRun? _current;

  ShellRun start(String command, Duration timeout,
      {Map<String, String>? environment, bool restart = false}) {
    final run = _IshRun(timeout);
    _queue = _queue.then((_) => _execute(run, command, timeout,
        environment: environment, restart: restart));
    return run;
  }

  Future<void> _execute(
    _IshRun run,
    String command,
    Duration timeout, {
    Map<String, String>? environment,
    bool restart = false,
  }) async {
    if (restart || _dead || _sessionId == null) {
      try {
        _sessionId = await _IshIsolate.instance.init(
          rootfsDir: _shell.rootfsDir,
          dataDir: _shell.dataDir,
          home: _home,
          env: _shell._compose(home: _home, environment: environment),
        );
        _dead = false;
        _shell._cwds[_cwdPath]?.value = _cwdPath;
      } catch (e) {
        run.state.complete(ShellResult.failed(
            "An error occurred while starting the iSH shell: $e"));
        return;
      }
    }

    final scriptB64 = base64.encode(utf8.encode(command));
    run.state.timeoutTimer = Timer(timeout, () => _interrupt(run, byTimeout: true));
    _current = run;

    try {
      final result = await _IshIsolate.instance.run(
        sessionId: _sessionId!,
        scriptB64: scriptB64,
        timeout: timeout,
      );
      _current = null;
      run.state.timeoutTimer?.cancel();
      if (!run.state.byTimeout) run.state.escalateTimer?.cancel();
      _shell._cwds[_cwdPath]?.value = result.cwd ?? _cwdPath;
      run.state.complete(result);
    } catch (e) {
      _current = null;
      run.state.timeoutTimer?.cancel();
      _dead = true;
      run.state.complete(ShellResult.failed(
          "An error occurred while executing the command: $e",
          output: run.state.output));
    }
  }

  void _interrupt(_IshRun run, {required bool byTimeout}) {
    if (run.state.interrupted || _current != run || _sessionId == null) return;
    run.state.interrupted = true;
    run.state.byTimeout = byTimeout || run.state.byTimeout;
    _IshIsolate.instance.interrupt(_sessionId!);
    run.state.escalateTimer = Timer(const Duration(seconds: 1), () {
      if (run.state.byTimeout || _current == run) _kill();
    });
  }

  void _kill() {
    final id = _sessionId;
    if (id != null) _IshIsolate.instance.destroy(id);
    _sessionId = null;
    _dead = true;
  }

  Future<void> close() async {
    _dead = true;
    final run = _current;
    _current = null;
    if (run != null && !run.state.done.isCompleted) {
      run.state.timeoutTimer?.cancel();
      run.state.escalateTimer?.cancel();
      run.state.complete(ShellResult(
        returnCode: -1,
        output: run.state.output,
        exceptionInfo: "The iSH shell was restarted while the command was running.",
      ));
    }
    final id = _sessionId;
    _sessionId = null;
    if (id != null) _IshIsolate.instance.destroy(id);
  }
}

class _IshRunState {
  _IshRunState(this.timeout);
  final Duration timeout;
  bool interrupted = false;
  bool byTimeout = false;
  final Completer<ShellResult> done = Completer();
  final List<String> chunks = [];
  String get output => chunks.join("");
  void complete(ShellResult result) {
    if (!done.isCompleted) done.complete(result);
  }

  Timer? timeoutTimer;
  Timer? escalateTimer;
}

class _IshRun implements ShellRun {
  _IshRun(this.timeout) : state = _IshRunState(timeout);
  final Duration timeout;
  final _IshRunState state;
  @override
  Future<ShellResult> get result => state.done.future;
  @override
  Future<void> kill() async {
    state.interrupted = true;
    state.byTimeout = false;
  }
}

class _IshOneShotRun implements ShellRun {
  _IshOneShotRun({
    required this.rootfsDir,
    required this.dataDir,
    required this.home,
    required this.script,
    required this.cwd,
    required this.timeout,
    required this.environment,
  }) {
    result = _run();
  }

  final String rootfsDir;
  final String dataDir;
  final String home;
  final String script;
  final String cwd;
  final Duration timeout;
  final Map<String, String> environment;

  @override
  late final Future<ShellResult> result;
  bool _killed = false;

  @override
  Future<void> kill() async => _killed = true;

  Future<ShellResult> _run() async {
    if (!ishLinked) {
      return const ShellResult.failed(
          "The iSH shell is not available on this platform.");
    }
    final id = await _IshIsolate.instance.init(
      rootfsDir: rootfsDir,
      dataDir: dataDir,
      home: home,
      env: environment,
    );
    final scriptB64 = base64.encode(utf8.encode(script));
    final timer = Timer(timeout, () => _IshIsolate.instance.interrupt(id));
    try {
      final res = await _IshIsolate.instance.run(
        sessionId: id,
        scriptB64: scriptB64,
        timeout: timeout,
      );
      if (_killed) {
        return ShellResult(
          returnCode: -1,
          output: res.output,
          exceptionInfo: "The command was interrupted and killed.",
        );
      }
      if (timer.isActive) return res;
      return ShellResult(
        returnCode: -1,
        output: res.output,
        exceptionInfo: "The command timed out after ${timeout.inSeconds}s. "
            "Anything it printed before that is above.",
      );
    } finally {
      timer.cancel();
      _IshIsolate.instance.destroy(id);
    }
  }
}

/// The long-lived background isolate that owns every iSH FFI handle. The
/// guest's execution blocks the calling thread, so commands are posted here and
/// the result comes back on the UI isolate.
///
/// An FFI pointer is only valid in the isolate that created it, so the isolate
/// is long-lived rather than one per command. The protocol is Lists over a
/// SendPort (the only thing transferable across isolate boundaries besides
/// primitives): `[tag, replyId, ...args]` for a request, `[replyId, result]`
/// for a reply.
class _IshIsolate {
  _IshIsolate._();
  static final _IshIsolate instance = _IshIsolate._();

  SendPort? _sendPort;
  int _nextReplyId = 1;
  final Map<int, Completer<dynamic>> _pending = {};

  // Message tags, as the first element of the List a SendPort carries.
  static const _kInit = 0;
  static const _kRun = 1;
  static const _kInterrupt = 2;
  static const _kDestroy = 3;
  static const _kReply = 4;

  Future<void> _ensure() async {
    if (_sendPort != null) return;
    final replies = ReceivePort();
    await Isolate.spawn(_entry, replies.sendPort);
    _sendPort = await replies.first as SendPort;
    replies.listen(_handle);
  }

  Future<int> init({
    required String rootfsDir,
    required String dataDir,
    required String home,
    required Map<String, String> env,
  }) async {
    if (!ishLinked) return -1;
    await _ensure();
    final replyId = _nextReplyId++;
    final reply = Completer<dynamic>();
    _pending[replyId] = reply;
    final sessionId = _nextReplyId++;
    _sendPort!.send([
      _kInit, replyId, sessionId, rootfsDir, dataDir, home,
      env.entries.map((e) => "${e.key}=${e.value}").toList(),
    ]);
    final error = await reply.future as String?;
    if (error != null) throw StateError(error);
    return sessionId;
  }

  Future<ShellResult> run({
    required int sessionId,
    required String scriptB64,
    required Duration timeout,
  }) async {
    if (!ishLinked) {
      return const ShellResult.failed("iSH is not linked into this build.");
    }
    await _ensure();
    final replyId = _nextReplyId++;
    final reply = Completer<dynamic>();
    _pending[replyId] = reply;
    _sendPort!.send([_kRun, replyId, sessionId, scriptB64, timeout.inMilliseconds]);
    return reply.future as ShellResult;
  }

  void interrupt(int sessionId) {
    _sendPort?.send([_kInterrupt, 0, sessionId]);
  }

  void destroy(int sessionId) {
    _sendPort?.send([_kDestroy, 0, sessionId]);
  }

  void _handle(dynamic msg) {
    if (msg is! List) return;
    final tag = msg[0] as int;
    if (tag != _kReply) return;
    final replyId = msg[1] as int;
    final c = _pending.remove(replyId);
    if (c == null) return;
    final error = msg[2] as String?;
    if (error != null) {
      c.completeError(StateError(error));
    } else {
      c.complete(msg[3]);
    }
  }

  static void _entry(SendPort main) {
    final receive = ReceivePort();
    main.send(receive.sendPort);
    final sessions = <int, ish_session_ptr>{};

    receive.listen((msg) {
      if (msg is! List) return;
      final tag = msg[0] as int;
      switch (tag) {
        case _kInit:
          final replyId = msg[1] as int;
          final sessionId = msg[2] as int;
          final rootfsDir = msg[3] as String;
          final dataDir = msg[4] as String;
          final home = msg[5] as String;
          final env = msg[6] as List;
          final initFn = ishInitFn;
          if (initFn == null) {
            main.send([_kReply, replyId, "iSH is not linked", null]);
            return;
          }
          // The env array as C strings.
          final envPtrs = calloc<Pointer<Utf8>>(env.length);
          for (var i = 0; i < env.length; i++) {
            envPtrs[i] = (env[i] as String).toNativeUtf8();
          }
          final errPtr = calloc<Pointer<Utf8>>();
          final handle = initFn(
            rootfsDir.toNativeUtf8(),
            dataDir.toNativeUtf8(),
            home.toNativeUtf8(),
            envPtrs,
            env.length,
            errPtr,
          );
          final error = errPtr.value.address == 0
              ? null
              : errPtr.value.cast<Utf8>().toDartString();
          for (var i = 0; i < env.length; i++) {
            calloc.free(envPtrs[i]);
          }
          calloc.free(envPtrs);
          calloc.free(errPtr);
          if (error == null && handle.address != 0) {
            sessions[sessionId] = handle;
          }
          main.send([_kReply, replyId, error, null]);

        case _kRun:
          final replyId = msg[1] as int;
          final sessionId = msg[2] as int;
          final scriptB64 = msg[3] as String;
          final timeoutMs = msg[4] as int;
          final runFn = ishRunFn;
          final handle = sessions[sessionId];
          if (runFn == null || handle == null) {
            main.send([_kReply, replyId, "session not found", null]);
            return;
          }
          final scriptPtr = scriptB64.toNativeUtf8();
          // The bridge posts the result through a callback. A synchronous
          // bridge fills a struct the isolate reads back; an async one posts
          // a _kReply once the marker lands. The contract is the same.
          final result = calloc<ish_result>();
          runFn(handle, scriptPtr, timeoutMs, nullptr, nullptr);
          final shellResult = result.ref.toShellResult();
          calloc.free(scriptPtr);
          calloc.free(result);
          main.send([_kReply, replyId, null, shellResult]);

        case _kInterrupt:
          final sessionId = msg[2] as int;
          final interruptFn = ishInterruptFn;
          final handle = sessions[sessionId];
          if (interruptFn != null && handle != null) {
            interruptFn(handle);
          }

        case _kDestroy:
          final sessionId = msg[2] as int;
          final destroyFn = ishDestroyFn;
          final handle = sessions.remove(sessionId);
          if (destroyFn != null && handle != null) {
            destroyFn(handle);
          }
      }
    });
  }
}
