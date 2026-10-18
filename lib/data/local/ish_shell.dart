import "dart:async";
import "dart:convert";
import "dart:ffi";
import "dart:isolate" show Isolate, ReceivePort, SendPort;
import "dart:typed_data" show Uint8List;

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
/// session map, each entry an iSH handle driven through `ish_ffi.dart` on that
/// session's own long-lived background isolate, so a guest command does not
/// block the UI and one chat's command does not wait on another chat's. A
/// stop does not ride that isolate — it is parked in its run's poll/read
/// loop for the run's whole life, so a message would queue behind the run it
/// is meant to end — so interrupt and its escalation go straight to the
/// bridge from the calling isolate, which the bridge is built for. See
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
        _transportFor = transport != null ? (() => transport) : IshWorker.new;

  /// Where the guest's rootfs is mounted from, asked per command: a Linux
  /// installed where none was reaches the next command, and one deleted stops
  /// being where commands run. The emulator mounts it once per process, so a
  /// different one picked or the same one reinstalled after the first command
  /// takes a restart. Empty where none is installed.
  final String Function() rootfsDir;

  /// The rootfs the first command booted the guest from: the one every later
  /// command runs in until a restart, see [rootfsDir].
  String? _bootedRootfs;

  /// The project workspace the guest's [guestHome] is bound to. The guest
  /// has one mount table for every session, so `/root` names one project at a
  /// time: a command in another project closes this one's idle sessions and
  /// the bridge rebinds; a busy one makes it wait. See "The workspace inside
  /// the guest" in ios/AGENTS.md.
  String? _boundHome;
  int _liveOneShots = 0;

  final String dataDir;

  final Map<String, String> Function() environment;

  final String Function() _describe;

  /// Whether the thing commands would run in is there. Empty is how "no
  /// Linux installed" reads here, and false is what keeps the agent from
  /// offering the tool a device cannot answer — the browser's rule.
  bool get rootfsInstalled => rootfsDir().isNotEmpty;

  @override
  String get platformDescription => _describe();

  /// The seam under [start]: one worker per session and one per one-shot run,
  /// or a test's fake for every owner. The suite runs where `ishLinked` is
  /// false, so without it the session logic would be reachable only from a
  /// device. One owner one isolate is what lets two chats' commands run at
  /// once — a run parks the worker thread that drives it.
  final IshTransport Function() _transportFor;

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
  String? get guestRoot => rootfsInstalled ? guestHome : null;

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
    final rootfs = rootfsDir();
    _bootedRootfs ??= rootfs;
    if (rootfs != _bootedRootfs) {
      return _IshUnavailableRun(
          "The Linux was changed after the guest started, and the guest runs "
          "the one it started with until the app restarts. Restart Entoli to "
          "run commands in the new one.");
    }
    final busy = _claimHome(home);
    if (busy != null) return _IshUnavailableRun(busy);
    // The guest's view of the chat workspace: the project workspace is bound
    // at [guestRoot], so the chat's own is that plus its suffix past the
    // project workspace — the same words the prompt tells the model.
    final guestCwd = guestWorkspacePath(guestRoot!, home, cwd);
    if (oneShot) {
      _liveOneShots++;
      final run = _IshOneShotRun(
        rootfsDir: rootfs,
        dataDir: dataDir,
        home: home,
        guestCwd: guestCwd,
        script: command,
        timeout: timeout,
        environment: _compose(extra: environment),
        transport: _transportFor(),
      );
      run.result.then((_) => _liveOneShots--,
          onError: (Object _) => _liveOneShots--);
      return run;
    }
    return _sessions
        .putIfAbsent(cwd, () => _IshSession(this, cwd, guestCwd, home))
        .start(command, timeout, environment: environment, restart: restart);
  }

  /// Point the guest's [guestHome] at [home]'s project, or say why not yet.
  /// Another project's idle sessions are closed — their next command starts
  /// cold — since their `/root` is about to name someone else's files.
  String? _claimHome(String home) {
    if (_boundHome != null && _boundHome != home) {
      if (_liveOneShots > 0 || _sessions.values.any((s) => s.busy)) {
        return "A command from another project is running in the Linux "
            "guest, which can hold one project's workspace at a time. Run "
            "this again once it finishes.";
      }
      for (final MapEntry(key: cwd, value: session) in _sessions.entries) {
        _cwds[cwd]?.value = session._guestCwd;
        session.close();
      }
      _sessions.clear();
    }
    _boundHome = home;
    return null;
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

  /// Where the session's own report names, mapped back through the binding:
  /// the gate's repo discovery walks the host, not the guest, and the shell's
  /// live words for where it stands are the guest's.
  @override
  String? sessionCwdInHostWords(String cwd) {
    final session = _sessions[cwd];
    return session?._hostWords();
  }

  Map<String, String> _compose({
    Map<String, String>? extra,
  }) =>
      {
        "PATH": guestPath,
        ...defaultShellEnvironment,
        "HOME": guestRoot ?? "/",
        ...environment(),
        ...?extra,
      };
}

class _IshSession {
  _IshSession(this._shell, this._cwdPath, this._guestCwd, this._workspaceHome)
      : _transport = _shell._transportFor();

  /// The session's own worker: the guest's run parks this isolate's thread,
  /// which is why it is shared with no other session. [close] ends it after
  /// the guest's destroy is queued.
  final IshTransport _transport;

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

  /// Where the guest says the shell is standing, in the guest's own words:
  /// the session's record, not [IshShell.sessionCwd]'s — that notifier
  /// exists only where something (the composer) asked, and this session's
  /// writes to it are no-ops where nobody did. Started at init, moved by
  /// each run's marker; what [sessionCwdInHostWords] maps back.
  String? _standing;
  Future<void> _queue = Future.value();
  _IshRun? _current;
  final List<_IshRun> _runs = [];

  /// Set by [close]: a queued `_execute` body reads it and boots nothing,
  /// its own run among the ones close answered.
  bool _closed = false;

  /// A run is pending or queued: the guest's `/root` must not move under it.
  bool get busy => _runs.any((r) => !r.state.done.isCompleted);

  ShellRun start(String command, Duration timeout,
      {Map<String, String>? environment, bool restart = false}) {
    final run = _IshRun(this);
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
    // close() answered every run, this body's among them; nothing here may
    // boot the guest it dropped.
    if (_closed) return;
    if (restart || _sessionId == null) {
      // A restart is asked of a session that may still be running: destroy
      // the old guest before making a new one, or the emulator keeps the
      // orphan for the rest of the process.
      final old = _sessionId;
      _sessionId = null;
      _handle = 0;
      if (old != null) _transport.destroy(old);
      try {
        final (:sessionId, :handle) = await _transport.init(
          rootfsDir: _shell.rootfsDir(),
          dataDir: _shell.dataDir,
          home: _workspaceHome,
          cwd: _guestCwd,
          env: _shell._compose(extra: environment),
        );
        // The transport's answer where iSH is not linked, which is a build
        // fault the user sees: taking the id would hang the session's whole
        // life on runs that can only fail it and on a bar dressed as if the
        // guest had come up.
        if (sessionId == -1) {
          run.state.complete(const ShellResult.failed(
              "The iSH shell is not available on this platform."));
          return;
        }
        _sessionId = sessionId;
        _handle = handle;
        _standing = _guestCwd;
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
      final result = await _transport.run(
        sessionId: _sessionId!,
        scriptB64: scriptB64,
        timeout: timeout,
        onOutput: run.state.pushOutput,
      );
      _current = null;
      run.state.timeoutTimer?.cancel();
      run.state.escalateTimer?.cancel();
      _standing = result.cwd ?? _guestCwd;
      _shell._cwds[_cwdPath]?.value = result.cwd ?? _guestCwd;
      // The model is told a stop or a timeout happened, as LocalShell's
      // session tells it; a hung-up run already says it did not complete.
      run.state.complete(!run.state.interrupted || result.exceptionInfo != null
          ? result
          : ShellResult(
              returnCode: result.returnCode,
              output: result.output,
              cwd: result.cwd,
              violations: result.violations,
              exceptionInfo: run.state.byTimeout
                  ? "The command timed out after ${timeout.inSeconds}s and "
                      "was interrupted. Anything it printed before that is "
                      "above."
                  : "The command was interrupted.",
            ));
    } catch (e) {
      _current = null;
      run.state.timeoutTimer?.cancel();
      final id = _sessionId;
      _sessionId = null;
      _handle = 0;
      // The run's own handle is gone with the failure; destroy it so the
      // guest does not outlive the command that lost it, and the next
      // command starts a session cold.
      if (id != null) _transport.destroy(id);
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
    if (_handle != 0) _transport.interrupt(_handle);
    run.state.escalateTimer = Timer(const Duration(seconds: 1), () {
      // What the escalation is for: a run still on the worker a second after
      // its SIGINT. An answered run is left alone — its session keeps the cd
      // and exports a hangup would take. On a timeout that is a deliberate
      // split from LocalShell, which kills the group at the command's own
      // sentinel to reach what ignored the interrupt; the one-shot takes
      // LocalShell's side, having no session state to keep.
      if (!run.state.done.isCompleted) _kill();
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
    if (handle != 0) _transport.hangup(handle);
    if (id != null) _transport.destroy(id);
  }

  /// Where the session stands, in the host's own words: the guest path its
  /// own record names, mapped back through the binding the bridge makes,
  /// /root at this session's home, [guestWorkspacePath]'s other direction.
  /// [pathInside] because the record can name a `cd` outside the workspace,
  /// which the machine has no host path to name either.
  String? _hostWords() {
    final standing = _standing;
    if (standing == null) return null;
    final root = _shell.guestRoot;
    if (root == null || !pathInside(standing, root)) return null;
    final suffix = standing == root ? "" : standing.substring(root.length);
    return "$_workspaceHome$suffix";
  }

  Future<void> close() {
    // Every run this session still holds is answered, not just the current
    // one: a queued run whose result nobody would complete is a turn that
    // never ends. A queued `_execute` body reading `_closed` boots nothing:
    // the guest it would have started is one this close would never see
    // again.
    final id = _sessionId;
    final handle = _handle;
    _sessionId = null;
    _handle = 0;
    // A worker parked in a run's poll would leave the destroy and the stop
    // queued behind it for the command's whole life; the hangup returns it.
    if (_current != null && handle != 0) _transport.hangup(handle);
    _current = null;
    _closed = true;
    if (id != null) _transport.destroy(id);
    _transport.stop();
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
  bool interrupted = false;
  bool byTimeout = false;

  /// What the command has printed so far, whole — the worker pushes every
  /// resolved chunk here as the bridge surfaces it. Published only where
  /// someone asks ([watched], the gate LocalShell's own run keeps), so a
  /// sub-agent's run nobody reads pays nothing for its chunks.
  final ValueNotifier<String?> output = ValueNotifier(null);
  bool watched = false;

  /// The bridge's old reply cap: the head is kept, the rest is the watch's
  /// anyway and the reply never grew past it.
  static const _outputCap = 65536;

  void pushOutput(String delta) {
    if (!watched) return;
    var next = (output.value ?? "") + delta;
    if (next.length > _outputCap) next = next.substring(0, _outputCap);
    output.value = next;
  }

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
  _IshRun(this._session);
  final _IshSession _session;
  final _IshRunState state = _IshRunState();
  @override
  Future<ShellResult> get result => state.done.future;
  @override
  ValueListenable<String?>? get output {
    // Asking is the watch: before this the session's chunks pay nothing for a
    // view nobody reads.
    state.watched = true;
    return state.output;
  }
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
    // The run owns its worker (sub-agent fan-out can overlap): it dies with
    // the run, after the tear-down's destroy, one order.
    result = _run().whenComplete(() => transport.stop());
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

  /// What the command has printed so far, the session run's accumulator.
  final _state = _IshRunState();

  @override
  late final Future<ShellResult> result;
  @override
  ValueListenable<String?>? get output {
    // Asking is the watch, as the session's run has it.
    _state.watched = true;
    return _state.output;
  }

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
        onOutput: _state.pushOutput,
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

  /// Run one command in the session's persistent guest shell. Parking on the
  /// worker between output chunks; interrupted and hung up from the outside.
  /// The command's output lands in [onOutput] the moment the bridge surfaces
  /// it — the run's watcher asks for it before the run starts — and null
  /// means nobody watches, so the chunks stop at the route.
  Future<ShellResult> run({
    required int sessionId,
    required String scriptB64,
    required Duration timeout,
    void Function(String)? onOutput,
  });

  /// SIGINT into the guest shell — the dispatcher's trap turns it into a 130
  /// while the shell survives, the contract LocalShell keeps.
  void interrupt(int handle);

  /// The escalation for a command that ignored the interrupt: the bridge
  /// kills the guest's process group and wakes the worker's poll, so its
  /// blocked run returns at once and its own destroy follows when it does.
  /// Non-blocking, safe to call while [run] is pending.
  void hangup(int handle);

  /// Free the guest and its handle on the worker.
  void destroy(int sessionId);

  /// End the transport's own isolate, after every destroy posted before it
  /// will have been applied.
  void stop();
}

/// The worker-side accumulator for one command's output: the bridge now reads
/// chunks for the worker's own loop (see [IshWorker]), and this separates what
/// the guest has said from the marker that ends the command — domain/shell's
/// [dispatcherMarker], which the C bridge used to match itself in
/// `parse_marker` — streaming what is settled through [onDelta] the moment it
/// cannot be marker text, and answering the command's result from [finish].
///
/// The bridge's own rules are kept: only a marker whose token is this
/// session's ends the run, rc first digit-run and a ` cwd=` up to `@@` (an
/// unterminated one waits for the next chunk); any other `@@E` line is
/// dropped with the line it ends on, the output before it kept and streamed;
/// and the reply keeps everything before the first marker, capped at its old
/// 64 KiB head. One honest divergence: a foreign-marker line may have already
/// reached the watch before the drop resolves, where the parked C call kept
/// every byte in its own buffer until the end.
class IshRunBuffer {
  IshRunBuffer({required this.token, this.onDelta})
      : _lead = "\n${dispatcherMarker(token)}".codeUnits;

  /// This session's dispatcher token — the only marker that ends the command.
  final String token;

  /// The full marker lead as bytes: `\n@@E<token> rc=`.
  final List<int> _lead;

  final void Function(String delta)? onDelta;

  void _emit(List<int> bytes) {
    if (bytes.isEmpty) return;
    final text = utf8.decode(bytes, allowMalformed: true);
    _reply += text;
    if (_reply.length > _replyCap) _reply = _reply.substring(0, _replyCap);
    onDelta?.call(text);
  }

  /// The bytes read but not yet classified: output still streaming, a marker
  /// that may be mid-arrival at the tail, or a foreign line being dropped.
  Uint8List _held = Uint8List(0);

  /// The marker has landed whole — [finish] answers from it and nothing that
  /// follows feeds anyone.
  bool done = false;

  int? _rc;
  String? _cwd;
  String _reply = "";
  String? _exception;

  /// The reply cap, in characters: the bridge's 64 KiB byte cap kept as the
  /// head, the model watching its own tail anyway.
  static const _replyCap = 65536;

  /// One bridge read. Bytes that can no longer be marker text are streamed
  /// once they are safe to split (whole UTF-8, past any marker prefix that
  /// the next chunk could still complete); the rest waits.
  void add(Uint8List chunk) {
    if (done || chunk.isEmpty) return;
    _held = _concat(_held, chunk);
    for (;;) {
      final m = _findMarkerStart(0);
      if (m < 0) {
        _streamAndHold();
        return;
      }
      final classify = _classify(m);
      if (!classify.known) {
        // The shape at [m] could still become this session's marker, but the
        // bytes have not arrived far enough to say: hold everything and wait.
        return;
      }
      if (classify.ours) {
        final parsed = _parseRcAndCwd(m + _lead.length);
        if (parsed == null) {
          // Ours so far, but the rc/cwd has not arrived whole: hold from the
          // marker and wait for the next chunk.
          _emit(_held.sublist(0, m));
          _held = _held.sublist(m);
          return;
        }
        _emit(_held.sublist(0, m));
        _rc = parsed.rc;
        _cwd = parsed.cwd;
        done = true;
        return;
      }
      // Not ours — another token's, or text on the marker's shape that does
      // not parse. The output before it is kept (the newline that opens the
      // shape with it, as the prior line's end) and the line itself is
      // dropped, the way the bridge dropped `stale` lines, so the scanner
      // does not trip over the same text again. Where the line has not ended
      // yet everything is held: dropping now would leak its remainder, which
      // arrives as an unrecognizable chunk later.
      final newline = _findByte(m + 1, 0x0A);
      if (newline < 0) return;
      _emit(_held.sublist(0, m + 1));
      _held = _held.sublist(newline + 1);
    }
  }

  /// The run is over however it is over: what is still held becomes the tail
  /// of the output up to the first marker shape, and a run whose marker never
  /// landed answers as the bridge's did — rc -1, "did not complete".
  ShellResult finish() {
    if (!done) {
      final cut = _findMarkerStart(0);
      final end = cut < 0 ? _held.length : cut;
      if (end > 0) _emit(_held.sublist(0, end));
      _exception = "The command did not complete.";
    }
    return ShellResult(
      returnCode: _rc ?? -1,
      output: _reply,
      cwd: _cwd,
      exceptionInfo: _exception,
    );
  }

  /// No marker found in what is held: stream everything except the longest
  /// tail that could still complete a marker, and keep that tail.
  void _streamAndHold() {
    var hold = 0;
    for (var n = _held.length; n > 0; n--) {
      if (_startsWith(_lead, 0, n, from: _held.length - n)) {
        hold = n;
        break;
      }
    }
    var cut = _held.length - hold;
    // A chunk can split a UTF-8 sequence: hold its bytes until the rest
    // arrives, or the persistent output shows a broken character forever.
    while (cut > 0 && (_held[cut - 1] & 0xC0) == 0x80) { cut--; }
    if (cut > 0 && (_held[cut - 1] & 0x80) != 0) {
      final leadByte = _held[cut - 1];
      final need =
          (leadByte & 0xF8) == 0xF0 ? 4 : (leadByte & 0xF0) == 0xE0 ? 3 : 2;
      if (_held.length - (cut - 1) < need) cut--;
    }
    _emit(_held.sublist(0, cut));
    _held = _held.sublist(cut);
  }

  /// How the `\n@@E` shape at [m] resolves. `known` false where the bytes
  /// have not arrived far enough to tell — the shape may still complete into
  /// this session's marker; `ours` false with `known` true where a byte has
  /// disproved it, which is the bridge's `stale` line.
  ({bool ours, bool known}) _classify(int m) {
    for (var i = 0; i < _lead.length; i++) {
      if (m + i >= _held.length) return (ours: false, known: false);
      if (_held[m + i] != _lead[i]) return (ours: false, known: true);
    }
    if (m + _lead.length >= _held.length) return (ours: false, known: false);
    final first = _held[m + _lead.length];
    final digit = first >= 0x30 && first <= 0x39;
    return (ours: digit, known: true);
  }
  /// The rc's digits and the ` cwd=<path>` up to `@@`, whole. Null where the
  /// bytes have not arrived far enough yet.
  ({int rc, String cwd})? _parseRcAndCwd(int start) {
    var i = start;
    while (i < _held.length && _held[i] >= 0x30 && _held[i] <= 0x39) {
      i++;
    }
    if (i == start) return null;
    const cwdEquals = [0x20, 0x63, 0x77, 0x64, 0x3D]; // " cwd="
    if (i + cwdEquals.length > _held.length) return null;
    for (var j = 0; j < cwdEquals.length; j++) {
      if (_held[i + j] != cwdEquals[j]) return null;
    }
    final cwdAt = i + cwdEquals.length;
    for (var k = cwdAt; k + 1 < _held.length; k++) {
      if (_held[k] == 0x40 && _held[k + 1] == 0x40) {
        return (
          rc: int.parse(
              utf8.decode(_held.sublist(start, i), allowMalformed: true)),
          cwd: utf8.decode(_held.sublist(cwdAt, k), allowMalformed: true),
        );
      }
    }
    return null;
  }

  /// The first index from [from] that begins the bare `\n@@E` shape the C
  /// bridge scanned for, or -1.
  int _findMarkerStart(int from) {
    const markerStart = [0x0A, 0x40, 0x40, 0x45];
    for (var i = from; i + markerStart.length <= _held.length; i++) {
      var matched = true;
      for (var j = 0; j < markerStart.length; j++) {
        if (_held[i + j] != markerStart[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return i;
    }
    return -1;
  }

  /// The first index from [from] holding [byte] — the newline that ends a
  /// foreign marker line — or -1.
  int _findByte(int from, int byte) {
    for (var i = from; i < _held.length; i++) {
      if (_held[i] == byte) return i;
    }
    return -1;
  }

  bool _startsWith(List<int> lead, int leadFrom, int leadTo, {required int from}) {
    if (from + leadTo - leadFrom > _held.length) return false;
    for (var i = leadFrom; i < leadTo; i++) {
      if (_held[from + i - leadFrom] != lead[i]) return false;
    }
    return true;
  }

  Uint8List _concat(Uint8List a, Uint8List b) {
    final merged = Uint8List(a.length + b.length);
    merged.setAll(0, a);
    merged.setAll(a.length, b);
    return merged;
  }
}

/// The long-lived background isolate that owns one iSH session's FFI handles —
/// every chat's persistent shell carries one, and so does every one-shot run.
/// The guest's execution blocks the calling thread, so commands are posted
/// here and the result comes back on the UI isolate.
///
/// An FFI pointer is only valid in the isolate that created it, so this
/// isolate is long-lived rather than one per command, and init and run are the
/// only calls that cross. Interrupt and hangup never do — the worker is parked
/// in its read while they matter — they are FFI calls made on the calling
/// isolate, over the handle's address, which the C heap makes valid there.
/// The protocol is Lists over a SendPort: `[tag, replyId, ...args]` for a
/// request, `[replyId, result]` for a reply.
class IshWorker implements IshTransport {
  IshWorker();

  SendPort? _sendPort;
  Future<void>? _starting;
  int _nextReplyId = 1;
  final Map<int, Completer<dynamic>> _pending = {};

  // Message tags, as the first element of the List a SendPort carries. The
  // kOutput ones ride between a run's request and its reply: the worker sends
  // one per resolved output chunk while the command is under way.
  static const _kInit = 0;
  static const _kRun = 1;
  static const _kDestroy = 2;
  static const _kReply = 3;
  static const _kOutput = 4;
  static const _kStop = 5;

  /// The watcher each run's chunks route to, keyed by reply id. Registered by
  /// [run] before the request goes, dropped when the reply lands or the
  /// worker dies.
  final Map<int, void Function(String)> _outputSinks = {};

  /// One order for init across every worker's isolate. The bridge's boot
  /// and binds (`ish_booted`, the static `bound_home` and `bound` in
  /// ish_bridge.c) are the C state two isolates could touch at once, and
  /// nothing locks them. The runs it orders stay parallel: each touches
  /// only its own task, whose mm, fds and signals the bridge gives the
  /// guest outright, and no destroy is here — teardown touches none of
  /// that state. A link that throws keeps the chain for the ones behind
  /// it and says so to its own caller.
  static Future<void> _ops = Future.value();

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
  void reset() {
    _sendPort = null;
    _starting = null;
    spawnCount = 0;
    for (final c in _pending.values) {
      c.completeError(_deadWorker());
    }
    _pending.clear();
    _outputSinks.clear();
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
      // Death before the hello is the one death whose caller is not in
      // [_pending] yet — the spawn future is what it waits on, so it is that
      // future's job to say the driver stopped.
      if (!ready.isCompleted) ready.completeError(_deadWorker());
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
  }) {
    final task = _ops.then((_) => _init(
          rootfsDir: rootfsDir,
          dataDir: dataDir,
          home: home,
          cwd: cwd,
          env: env,
        ));
    _ops = task.then((_) {}, onError: (_) {});
    return task;
  }

  Future<({int sessionId, int handle})> _init({
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
    _post(replyId, [
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
    void Function(String)? onOutput,
  }) async {
    if (!ishLinked) {
      return const ShellResult.failed("iSH is not linked into this build.");
    }
    await _ensure();
    final replyId = _nextReplyId++;
    final reply = Completer<dynamic>();
    _pending[replyId] = reply;
    if (onOutput != null) _outputSinks[replyId] = onOutput;
    _post(replyId, [_kRun, replyId, sessionId, scriptB64, timeout.inMilliseconds]);
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

  /// Post a request whose reply will come to [replyId]. Throws when the
  /// worker is gone, taking its own registration with it — the reset that
  /// fires on death answers completers it knows, and none of its business is
  /// the completer a caller registered between its own `_ensure` and here.
  void _post(int replyId, List<dynamic> request) {
    final port = _sendPort;
    if (port == null) {
      _pending.remove(replyId);
      throw _deadWorker();
    }
    port.send(request);
  }

  static StateError _deadWorker() => StateError("The iSH driver stopped.");

  @override
  void destroy(int sessionId) {
    // Immediate, not chained: teardown touches no boot state. A stop
    // posted after it lands behind it on this same port.
    _sendPort?.send([_kDestroy, 0, sessionId]);
  }

  /// End the isolate once the messages queued before it have applied — the
  /// destroy it follows, this port's own order. Pending replies are the
  /// exitPort's to fail, as for a crashed worker.
  @override
  void stop() {
    _sendPort?.send([_kStop, 0]);
  }

  void _handle(dynamic msg) {
    if (msg is! List) return;
    final tag = msg[0] as int;
    if (tag == _kOutput) {
      final sink = _outputSinks[msg[1] as int];
      if (sink != null) sink(msg[2] as String);
      return;
    }
    if (tag != _kReply) return;
    final replyId = msg[1] as int;
    final c = _pending.remove(replyId);
    _outputSinks.remove(replyId);
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
    // The worker's own session table: the handle every FFI step goes through
    // and the session's dispatcher token, which is what its marker feed
    // matches the command's end by.
    final sessions =
        <int, ({IshSessionPtr handle, String token})>{};

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
            sessions[sessionId] = (handle: handle, token: token);
          }
          main.send([_kReply, replyId, error, handle.address]);

        case _kRun:
          final replyId = msg[1] as int;
          final sessionId = msg[2] as int;
          final scriptB64 = msg[3] as String;
          final sess = sessions[sessionId];
          final drainFn = ishDrainWakeFn;
          final writeFn = ishWriteStdinFn;
          final pollFn = ishPollFn;
          final readFn = ishReadFn;
          if (sess == null || drainFn == null || pollFn == null ||
              readFn == null || writeFn == null) {
            main.send([_kReply, replyId, "session not found", null]);
            return;
          }
          // The command is the worker's own loop now, not one parked call:
          // poll wakes per output chunk or on the stop's byte, and every read
          // goes straight to the run's watch as it is resolved. Parking
          // between chunks on the bridge's poll is what keeps a stop reachable
          // while the command lives — the loop's bytes stream from here down
          // to [_handle], and the marker is Dart's from [IshRunBuffer]'s take
          // on it, so the feed never shows command work as guest output.
          final buf = calloc<Uint8>(65536);
          final feed = IshRunBuffer(token: sess.token,
              onDelta: (delta) => main.send([_kOutput, replyId, delta]));
          try {
            drainFn(sess.handle);
            final scriptPtr = scriptB64.toNativeUtf8();
            writeFn(sess.handle, scriptPtr);
            calloc.free(scriptPtr);
            while (!feed.done) {
              final flags = pollFn(sess.handle);
              if (flags < 0) break;  // a poll we cannot trust
              if (flags & 2 != 0) break;  // the hangup's byte
              if (flags & 1 == 0) continue;  // nothing yet (cannot stand)
              final n = readFn(sess.handle, buf, 65536);
              if (n < 0) {
                if (n == -2) continue;  // transient
                break;
              }
              if (n == 0) break;  // EOF: the guest shell is gone
              feed.add(Uint8List.fromList(buf.asTypedList(n)));
            }
          } finally {
            calloc.free(buf);
          }
          main.send([_kReply, replyId, null, feed.finish()]);

        case _kDestroy:
          final sessionId = msg[2] as int;
          final destroyFn = ishDestroyFn;
          final sess = sessions.remove(sessionId);
          if (destroyFn != null && sess != null) {
            destroyFn(sess.handle);
          }

        case _kStop:
          Isolate.exit();
      }
    });
  }
}
