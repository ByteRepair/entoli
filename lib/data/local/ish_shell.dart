import "dart:async";
import "dart:convert";
import "dart:ffi";
import "dart:isolate" show Isolate, ReceivePort, SendPort;

import "package:ffi/ffi.dart";
import "package:flutter/foundation.dart"
    show ValueListenable, ValueNotifier, visibleForTesting;
import "package:uuid/uuid.dart";

import "../../domain/file_tools.dart";
import "../../domain/shell.dart";
import "ish_ffi.dart";

/// The iOS shell. iOS denies an app a child process, so the host shell every
/// other platform has — one that does `Process.start` of `/bin/sh` or a bundled
/// `proot` — cannot work here. iSH runs the whole guest in-process, and this
/// is the `Shell` that drives it through the FFI bridge
/// (`tool/ios/ish/ish_bridge.c`). See ios/AGENTS.md.
///
/// It does not extend `LocalShell`: `LocalShell`'s persistent session is a
/// single child process whose stdin is fed base64 lines and whose stdout is
/// read for a marker, and iOS has no child process to be. This carries its own
/// session map, each entry an iSH handle driven through `ish_ffi.dart` on a
/// long-lived background isolate, so a guest command does not block the UI.
/// A stop does not ride that isolate — it is stuck in its read for the run's
/// whole life — so interrupt and its escalation go straight to the bridge
/// from the calling isolate, which the bridge is built for. See
/// [IshTransport].
///
/// The dispatcher script (`dispatcherScript` in `domain/shell.dart`) is passed
/// to the C bridge and runs inside the guest's own `/bin/sh`, so a `cd` or an
/// `export` in one emulated command sticks for the next, the same contract the
/// host shell keeps. The marker the guest writes back is parsed for the exit
/// code and the directory the shell is now in, the same way `LocalShell._Session`
/// parses its child process's output.
class IshShell extends Shell {
  IshShell({
    required this.rootfsDir,
    required this.dataDir,
    required this.environment,
    required String Function() platformDescription,
    IshTransport? transport,
  })  : _describe = platformDescription,
        transport = transport ?? IshWorker.instance;

  /// Where the guest's rootfs is mounted from, asked per command: a Linux
  /// installed from the settings page reaches the next command, and one
  /// deleted stops being where commands run without the app having to be
  /// restarted. Empty where none is installed. Held as the closure itself —
  /// an initializing formal rather than a private field under a differently
  /// named parameter, which is what `prefer_initializing_formals` asks for
  /// and what CI's analyzer refuses otherwise.
  final String Function() rootfsDir;

  final String dataDir;

  final Map<String, String> Function() environment;

  final String Function() _describe;

  /// Where the rootfs directory is on the host: one ask of [rootfsDir].
  String get rootfsPath => rootfsDir();

  /// Whether the thing commands would run in is there. Empty is how "no
  /// Linux installed" reads here, and false is what keeps the agent from
  /// offering the tool a device cannot answer — the browser's rule.
  bool get rootfsInstalled => rootfsDir().isNotEmpty;

  @override
  String get platformDescription => _describe();

  /// The seam under [start]: the real worker isolate, or a test's fake. The
  /// suite runs where `ishLinked` is false, so without it the session logic
  /// would be reachable only from a device.
  final IshTransport transport;

  final Map<String, _IshSession> _sessions = {};
  final Map<String, ValueNotifier<String?>> _cwds = {};

  @override
  bool get canRunCommands => rootfsInstalled;

  @override
  bool get projectHome => true;

  /// Where the project workspace appears inside the guest: `/root`, the same
  /// clean path proot binds it at on Android, so the model is told `~` and
  /// the paths it reads back are short rather than the app container's own.
  /// Null where no Linux is installed — there is no guest to mask anything
  /// in, and the file tools then resolve host paths directly.
  @override
  String? get guestRoot => rootfsInstalled ? "/root" : null;

  /// What `HOME` is for a command here: the guest path where the project
  /// workspace is bound, so `~` in a command expands to it and the prompt,
  /// the file tools and [_compose] all say the same place. The workspace is
  /// reachable at `$guestRoot` + its suffix past the project workspace.
  @override
  String? homeFor(String home) => guestRoot ?? home;

  @override
  ShellRun start(String command,
      {required String cwd,
      required String home,
      required Duration timeout,
      Map<String, String>? environment,
      bool oneShot = false,
      bool restart = false,
      String? project,
      CommandSandbox? sandbox}) {
    // `project` exists so a shell can resolve a per-project driver; the
    // emulator is its own environment and has no driver to pick.
    //
    // There is no confinement to offer inside the guest — its rootfs is the
    // boundary, the way a proot guest's is — so a sandboxed command fails
    // closed rather than running unconfined, the way a host shell without
    // Landlock does.
    if (sandbox != null) {
      return _IshUnavailableRun(
          "No sandbox is available in the guest to run this command confined, "
          "so it was not run.");
    }
    if (!rootfsInstalled) {
      return _IshUnavailableRun(
          "No Linux is installed on this device to run commands in. Install "
          "one from the Terminal settings.");
    }
    // The guest's view of the chat workspace: the project workspace is bound
    // at [guestRoot], so the chat's own is that plus its suffix past the
    // project workspace — the same words the prompt tells the model.
    final guestCwd = guestWorkspacePath(guestRoot!, home, cwd);
    if (oneShot) {
      return _IshOneShotRun(
        rootfsDir: rootfsPath,
        dataDir: dataDir,
        home: home,
        guestCwd: guestCwd,
        script: command,
        timeout: timeout,
        environment: _compose(extra: environment),
        transport: transport,
      );
    }
    return _sessions
        .putIfAbsent(cwd, () => _IshSession(this, cwd, guestCwd, home))
        .start(command, timeout, environment: environment, restart: restart);
  }

  /// Seeded with the guest's own words for [cwd] — the host path it is keyed
  /// by is not where anything stands in the guest, and until the first marker
  /// lands there is no other report to hold. [home] is the project workspace
  /// the turn path hands every start.
  @override
  ValueListenable<String?>? sessionCwd(String cwd, {String? home}) =>
      // [_cwds] keyed host-path: the turn path's [_IshSession] updates the
      // value from the guest's own marker once something has run.
      _cwds.putIfAbsent(
          cwd, () => ValueNotifier<String?>(_guestViewOf(cwd, home)));

  String? _guestViewOf(String cwd, String? home) {
    final root = guestRoot;
    return root != null && home != null
        ? guestWorkspacePath(root, home, cwd)
        : null;
  }

  @override
  void closeSession(String cwd) {
    _cwds.remove(cwd)?.dispose();
    _sessions.remove(cwd)?.close();
  }

  Map<String, String> _compose({
    Map<String, String>? extra,
  }) =>
      {
        // The guest's own PATH: a non-login ash falls back to its
        // compiled-in default, which does not name /usr/local/bin — where a
        // setup's installs land — and a `command not found` one command at a
        // time is how that would be noticed.
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        ...defaultShellEnvironment,
        "HOME": guestRoot ?? "/",
        ...environment(),
        ...?extra,
      };
}

class _IshSession {
  _IshSession(this._shell, this._cwdPath, this._guestCwd, this._workspaceHome);

  final IshShell _shell;
  final String _cwdPath;

  /// The chat workspace in the guest's own words — what the session's shell
  /// starts in, and what its marker's `cwd=` comes back as.
  final String _guestCwd;

  /// The host project workspace, which the bridge binds into the guest at
  /// [IshShell.guestRoot].
  final String _workspaceHome;

  int? _sessionId;

  /// The C handle's address, shared with [IshTransport.init]'s answer. The
  /// interrupt and hangup below are delivered from this isolate over it — the
  /// worker cannot deliver either while it is parked in its read.
  int _handle = 0;
  Future<void> _queue = Future.value();
  _IshRun? _current;
  final List<_IshRun> _runs = [];

  ShellRun start(String command, Duration timeout,
      {Map<String, String>? environment, bool restart = false}) {
    final run = _IshRun(timeout, this);
    _runs.add(run);
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
    if (restart || _sessionId == null) {
      // A restart is asked of a session that may still be running: destroy
      // the old guest before making a new one, or the emulator keeps the
      // orphan for the rest of the process.
      final old = _sessionId;
      _sessionId = null;
      _handle = 0;
      if (old != null) _shell.transport.destroy(old);
      try {
        final (:sessionId, :handle) = await _shell.transport.init(
          rootfsDir: _shell.rootfsPath,
          dataDir: _shell.dataDir,
          home: _workspaceHome,
          cwd: _guestCwd,
          env: _shell._compose(extra: environment),
        );
        _sessionId = sessionId;
        _handle = handle;
        _shell._cwds[_cwdPath]?.value = _guestCwd;
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
      final result = await _shell.transport.run(
        sessionId: _sessionId!,
        scriptB64: scriptB64,
        timeout: timeout,
      );
      _current = null;
      run.state.timeoutTimer?.cancel();
      if (!run.state.byTimeout) run.state.escalateTimer?.cancel();
      _shell._cwds[_cwdPath]?.value = result.cwd ?? _guestCwd;
      run.state.complete(result);
    } catch (e) {
      _current = null;
      run.state.timeoutTimer?.cancel();
      final id = _sessionId;
      _sessionId = null;
      _handle = 0;
      // The run's own handle is gone with the failure; destroy it so the
      // guest does not outlive the command that lost it, and the next
      // command starts a session cold.
      if (id != null) _shell.transport.destroy(id);
      run.state.complete(ShellResult.failed(
          "An error occurred while executing the command: $e"));
    }
  }

  void _interrupt(_IshRun run, {required bool byTimeout}) {
    if (run.state.interrupted || _current != run || _sessionId == null) return;
    run.state.interrupted = true;
    run.state.byTimeout = byTimeout || run.state.byTimeout;
    // Delivered here, not posted to the worker: the worker is blocked in its
    // own read for the whole of this command, so a message would queue behind
    // the run it is meant to end. The bridge's interrupt is a send_signal the
    // guest's interpreter thread honours at its next scheduling point — it is
    // built to be poked from another thread, and this is a third one.
    if (_handle != 0) _shell.transport.interrupt(_handle);
    run.state.escalateTimer = Timer(const Duration(seconds: 1), () {
      if (run.state.byTimeout || _current == run) _kill();
    });
  }

  void _kill() {
    final handle = _handle;
    _handle = 0;
    final id = _sessionId;
    _sessionId = null;
    // The hangup is what unblocks the worker's own read — the destroy queued
    // beside it is applied the moment the run returns, which is now seconds
    // away rather than never. The handle's freeing stays the destroy's.
    if (handle != 0) _shell.transport.hangup(handle);
    if (id != null) _shell.transport.destroy(id);
  }

  Future<void> close() {
    // Every run this session still holds is answered, not just the current
    // one: a queued run whose result nobody would complete is a turn that
    // never ends. The queued `_execute` bodies read `_sessionId` after this,
    // so nulling it first is what sends each of them to the failed-complete
    // path rather than into a fresh session nothing will ever close.
    final id = _sessionId;
    _sessionId = null;
    _handle = 0;
    _current = null;
    if (id != null) _shell.transport.destroy(id);
    for (final run in _runs) {
      if (!run.state.done.isCompleted) {
        run.state.timeoutTimer?.cancel();
        run.state.escalateTimer?.cancel();
        run.state.complete(ShellResult(
          returnCode: -1,
          output: "",
          exceptionInfo:
              "The iSH shell was restarted while the command was running.",
        ));
      }
    }
    _runs.clear();
    return Future.value();
  }
}

class _IshRunState {
  _IshRunState(this.timeout);
  final Duration timeout;
  bool interrupted = false;
  bool byTimeout = false;
  final Completer<ShellResult> done = Completer();
  void complete(ShellResult result) {
    if (!done.isCompleted) done.complete(result);
  }

  Timer? timeoutTimer;
  Timer? escalateTimer;
}

/// The run a command carries when there is nothing to run it with — no
/// sandbox in the guest for a confined command, or no Linux installed for
/// anything. Completes failed instead of leaving the caller's
/// `await run.result` waiting on a run that never started.
class _IshUnavailableRun implements ShellRun {
  _IshUnavailableRun(this.message);

  final String message;

  @override
  Future<ShellResult> get result async => ShellResult.failed(message);

  @override
  ValueListenable<String?>? get output => null;

  @override
  Future<void> kill() async {}
}

class _IshRun implements ShellRun {
  _IshRun(this.timeout, this._session) : state = _IshRunState(timeout);
  final Duration timeout;
  final _IshSession _session;
  final _IshRunState state;
  @override
  Future<ShellResult> get result => state.done.future;
  @override
  ValueListenable<String?>? get output => null;
  @override
  Future<void> kill() async => _session._interrupt(this, byTimeout: false);
}

class _IshOneShotRun implements ShellRun {
  _IshOneShotRun({
    required this.rootfsDir,
    required this.dataDir,
    required this.home,
    required this.guestCwd,
    required this.script,
    required this.timeout,
    required this.environment,
    required this.transport,
  }) {
    result = _run();
  }

  final String rootfsDir;
  final String dataDir;

  /// The host project workspace, which the bridge binds at the guest root.
  final String home;

  /// Where the one-shot shell starts, in the guest's own words.
  final String guestCwd;
  final String script;
  final Duration timeout;
  final Map<String, String> environment;

  final IshTransport transport;
  int? _sessionId;
  int _handle = 0;
  bool _interrupted = false;
  Timer? _escalateTimer;

  @override
  late final Future<ShellResult> result;
  @override
  ValueListenable<String?>? get output => null;

  @override
  Future<void> kill() async => _stop();

  /// Stop, escalate, and otherwise end the run: the interrupt is delivered
  /// from this isolate — a message to the worker would queue behind the run —
  /// and the escalation is [ish_session_hangup], which is what turns a guest
  /// that ignored the SIGINT into a result a second later.
  void _stop() {
    if (_interrupted || _sessionId == null) return;
    _interrupted = true;
    if (_handle != 0) transport.interrupt(_handle);
    _escalateTimer = Timer(const Duration(seconds: 1), () {
      if (_handle != 0) {
        transport.hangup(_handle);
        _handle = 0;
      }
    });
  }

  Future<ShellResult> _run() async {
    late final int sessionId;
    late final int handle;
    try {
      final session = await transport.init(
        rootfsDir: rootfsDir,
        dataDir: dataDir,
        home: home,
        cwd: guestCwd,
        env: environment,
      );
      sessionId = session.sessionId;
      handle = session.handle;
      if (sessionId == -1) {
        return const ShellResult.failed(
            "The iSH shell is not available on this platform.");
      }
    } catch (e) {
      return ShellResult.failed(
          "An error occurred while starting the iSH shell: $e");
    }
    _sessionId = sessionId;
    _handle = handle;
    final scriptB64 = base64.encode(utf8.encode(script));
    final timer = Timer(timeout, _stop);
    try {
      final res = await transport.run(
        sessionId: _sessionId!,
        scriptB64: scriptB64,
        timeout: timeout,
      );
      if (!timer.isActive) {
        return ShellResult(
          returnCode: -1,
          output: res.output,
          exceptionInfo: "The command timed out after ${timeout.inSeconds}s. "
              "Anything it printed before that is above.",
        );
      }
      return res;
    } finally {
      timer.cancel();
      _escalateTimer?.cancel();
      transport.destroy(_sessionId!);
    }
  }
}

/// The seam under the shell: what a session's init, run, stop and teardown go
/// through. The real one is [IshWorker]. A test stands a fake in here,
/// because the suite runs where `ishLinked` is false and the worker would
/// answer nothing.
abstract class IshTransport {
  /// Make a session. Answers the id the worker routes runs and destroys by,
  /// and the C handle's address — which is what [interrupt] and [hangup] go
  /// by, both delivered on the calling isolate. Id `-1` is the answer where
  /// iSH is not linked; init throwing is a failed boot.
  Future<({int sessionId, int handle})> init({
    required String rootfsDir,
    required String dataDir,
    required String home,
    required String cwd,
    required Map<String, String> env,
  });

  /// Run one command in the session's persistent guest shell. Blocking on the
  /// worker for the command's whole life; interrupted and hung up from the
  /// outside.
  Future<ShellResult> run({
    required int sessionId,
    required String scriptB64,
    required Duration timeout,
  });

  /// SIGINT into the guest shell — the dispatcher's trap turns it into a 130
  /// while the shell survives, the contract LocalShell keeps.
  void interrupt(int handle);

  /// The escalation for a command that ignored the interrupt: the bridge
  /// kills the guest and closes the read end, so the worker's blocked run
  /// returns at once and its own destroy follows when it does. Non-blocking,
  /// safe to call while [run] is pending.
  void hangup(int handle);

  /// Free the guest and its handle on the worker.
  void destroy(int sessionId);
}

/// The long-lived background isolate that owns every iSH FFI handle. The
/// guest's execution blocks the calling thread, so commands are posted here and
/// the result comes back on the UI isolate.
///
/// An FFI pointer is only valid in the isolate that created it, so the isolate
/// is long-lived rather than one per command, and init and run are the only
/// calls that cross. Interrupt and hangup never do — the worker is parked in
/// its read while they matter — they are FFI calls made on the calling
/// isolate, over the handle's address, which the C heap makes valid there.
/// The protocol is Lists over a SendPort: `[tag, replyId, ...args]` for a
/// request, `[replyId, result]` for a reply.
class IshWorker implements IshTransport {
  IshWorker._();
  static final IshWorker instance = IshWorker._();

  SendPort? _sendPort;
  Future<void>? _starting;
  int _nextReplyId = 1;
  final Map<int, Completer<dynamic>> _pending = {};

  // Message tags, as the first element of the List a SendPort carries.
  static const _kInit = 0;
  static const _kRun = 1;
  static const _kDestroy = 2;
  static const _kReply = 3;

  /// How many workers have been spawned — test-visible, so the single flight
  /// of [_ensure] is pinned: two concurrent first users answer one spawn.
  @visibleForTesting
  int spawnCount = 0;

  /// The worker's spawn is single-flighted: the future is made the moment the
  /// first caller proceeds, before its first await, so two concurrent first
  /// inits both walk into the same `Isolate.spawn` and one isolate serves
  /// every handle. The old `_sendPort != null` check spawned one isolate per
  /// caller that got past it — the race the review found.
  Future<void> _ensure() => _starting ??= _spawn();

  @visibleForTesting
  Future<void> ensureStarted() => _ensure();

  /// Forget the worker and every pending reply. A worker that died (an FFI
  /// crash inside it) otherwise leaves its completers open and every run on
  /// them hanging past the end of its turn.
  @visibleForTesting
  void reset() {
    _sendPort = null;
    _starting = null;
    spawnCount = 0;
    for (final c in _pending.values) {
      c.completeError(StateError("The iSH driver stopped."));
    }
    _pending.clear();
  }

  Future<void> _spawn() async {
    final replies = ReceivePort();
    final exitPort = ReceivePort();
    await Isolate.spawn(_entry, replies.sendPort, onExit: exitPort.sendPort);
    spawnCount++;
    // One listener for the port's whole life: a ReceivePort is a
    // single-subscription stream, so reading the entry's hello with `.first`
    // and then attaching the real listener would throw at the second one.
    final ready = Completer<SendPort>();
    late final StreamSubscription<dynamic> repliesSub;
    repliesSub = replies.listen((msg) {
      if (msg is SendPort && !ready.isCompleted) {
        ready.complete(msg);
        return;
      }
      _handle(msg);
    });
    exitPort.listen((_) {
      repliesSub.cancel();
      exitPort.close();
      reset();
    });
    _sendPort = await ready.future;
  }

  @override
  Future<({int sessionId, int handle})> init({
    required String rootfsDir,
    required String dataDir,
    required String home,
    required String cwd,
    required Map<String, String> env,
  }) async {
    if (!ishLinked) return (sessionId: -1, handle: 0);
    await _ensure();
    final token = const Uuid().v4();
    final dispatcher = dispatcherScript(token);
    final replyId = _nextReplyId++;
    final reply = Completer<dynamic>();
    _pending[replyId] = reply;
    final sessionId = _nextReplyId++;
    _sendPort!.send([
      _kInit, replyId, sessionId, rootfsDir, dataDir, home, cwd,
      dispatcher, token,
      env.entries.map((e) => "${e.key}=${e.value}").toList(),
    ]);
    final handle = await reply.future as int;
    return (sessionId: sessionId, handle: handle);
  }

  @override
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
    return await reply.future as ShellResult;
  }

  @override
  void interrupt(int handle) => _poke(ishInterruptFn, handle);

  @override
  void hangup(int handle) => _poke(ishHangupFn, handle);

  /// One of the two never-blocking bridging calls, made here rather than
  /// posted: the worker is unavailable while a run it owns is pending, and
  /// that is exactly when these have to land.
  void _poke(void Function(IshSessionPtr)? fn, int address) {
    if (fn != null) fn(Pointer.fromAddress(address));
  }

  @override
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
    final sessions = <int, IshSessionPtr>{};

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
          final cwd = msg[6] as String;
          final dispatcher = msg[7] as String;
          final token = msg[8] as String;
          final env = msg[9] as List;
          final initFn = ishInitFn;
          if (initFn == null) {
            main.send([_kReply, replyId, "iSH is not linked", null]);
            return;
          }
          // The env array as C strings. Every string handed to the bridge is
          // ours to free after the call — the bridge copies what it keeps.
          final envPtrs = calloc<Pointer<Utf8>>(env.length);
          final argPtrs = [
            rootfsDir.toNativeUtf8(),
            dataDir.toNativeUtf8(),
            home.toNativeUtf8(),
            cwd.toNativeUtf8(),
            dispatcher.toNativeUtf8(),
            token.toNativeUtf8(),
          ];
          for (var i = 0; i < env.length; i++) {
            envPtrs[i] = (env[i] as String).toNativeUtf8();
          }
          final errPtr = calloc<Pointer<Utf8>>();
          final handle = initFn(
            argPtrs[0],
            argPtrs[1],
            argPtrs[2],
            argPtrs[3],
            argPtrs[4],
            argPtrs[5],
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
          for (final p in argPtrs) {
            calloc.free(p);
          }
          if (error == null && handle.address != 0) {
            sessions[sessionId] = handle;
          }
          main.send([_kReply, replyId, error, handle.address]);

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
          final result = calloc<IshResult>();
          runFn(handle, scriptPtr, timeoutMs, result);
          final shellResult = result.ref.toShellResult();
          if (result.ref.output.address != 0) {
            calloc.free(result.ref.output);
          }
          if (result.ref.cwd.address != 0) {
            calloc.free(result.ref.cwd);
          }
          if (result.ref.exception.address != 0) {
            calloc.free(result.ref.exception);
          }
          calloc.free(scriptPtr);
          calloc.free(result);
          main.send([_kReply, replyId, null, shellResult]);

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
