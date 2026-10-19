/// The browser's `Shell`: commands run in the Linux the page emulates, through
/// `entoli-mux`. The contract is `LocalShell`'s — one persistent shell per
/// chat speaking the dispatcher in `domain/shell.dart`, a stop that is a
/// Ctrl-C to the group before it is a kill, one-shots for sub-agents — with a
/// process in the guest where `LocalShell` has one on the machine. See "The
/// browser's Linux" in `lib/data/web/AGENTS.md`.
library;

import "dart:async";
import "dart:convert";

import "package:flutter/foundation.dart" show ValueListenable, ValueNotifier;
import "package:fs_shim/fs.dart";
import "package:uuid/uuid.dart";

import "../../core/log.dart";
import "../../domain/shell.dart";
import "guest_mux.dart";

const _sigint = 2;
const _sigkill = 9;

/// How long a stop or a timeout waits on the interrupt before killing.
const _grace = Duration(seconds: 1);

/// What the flush of a pipe whose writers have gone is worth waiting for.
const _drainGrace = Duration(seconds: 2);

/// How much of a running command's output the live view holds.
const _liveWindow = 8192;

/// The head of the sentinel, held back from the live view while it may still
/// be forming.
const _markerPrefix = "\n@@E";

String _word(Duration d) =>
    d.inMilliseconds < 1000 ? "${d.inMilliseconds}ms" : "${d.inSeconds}s";

String _liveTail(String prior, String piece) {
  final out = prior + piece;
  return out.length > _liveWindow ? out.substring(out.length - _liveWindow) : out;
}

class GuestShell extends Shell {
  GuestShell({
    required this.guest,
    required this.available,
    required String Function() description,
    required this.environment,
    required this.fs,
  }) : _describe = description;

  /// The guest, booted by the first command that needs it and the same one
  /// from then on.
  final Future<GuestMux> Function() guest;

  /// Whether the site serves a Linux at all, asked per command.
  final bool Function() available;
  final String Function() _describe;

  /// The app's command environment, read per command.
  final Map<String, String> Function() environment;
  final FileSystem fs;

  final Map<String, _Session> _sessions = {};
  final Map<String, ValueNotifier<String?>> _cwds = {};

  @override
  String get platformDescription => _describe();

  @override
  bool get canRunCommands => available();

  /// A command's `HOME` is the project workspace: the guest's own `/root` is
  /// one directory every project would share.
  @override
  bool get projectHome => true;

  /// The guest mounts the data directory at its own path, so the workspace
  /// is one path to both sides and there is no mask to apply.
  @override
  String? homeFor(String home) => home;

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
    // The guest is the boundary, the way a proot guest is; a command that
    // asked to be confined further fails closed rather than running without.
    if (sandbox != null) {
      return _Failed("No sandbox is available in this page's Linux to run "
          "this command confined, so it was not run.");
    }
    if (!available()) {
      return _Failed("This page has no Linux to run commands in.");
    }
    if (oneShot) {
      return _OneShotRun(this, command, cwd: cwd, home: home, timeout: timeout,
          environment: environment);
    }
    return _sessions
        .putIfAbsent(cwd, () => _Session(this, cwd, home))
        .start(command, timeout, environment: environment, restart: restart);
  }

  @override
  ValueListenable<String?>? sessionCwd(String cwd, {String? home}) =>
      _cwds.putIfAbsent(cwd, () => ValueNotifier<String?>(cwd));

  @override
  String? sessionCwdInHostWords(String cwd) => _sessions[cwd]?._standing;

  @override
  void closeSession(String cwd) {
    _cwds.remove(cwd)?.dispose();
    _sessions.remove(cwd)?.close();
  }

  Map<String, String> _compose(String home, Map<String, String>? extra) => {
        "PATH": guestPath,
        ...defaultShellEnvironment,
        "HOME": home,
        ...environment(),
        ...?extra,
      };

  /// The guest, with [cwd] made: a project workspace before its first chat
  /// is a directory the app has not laid out yet.
  Future<GuestMux> _ready(String cwd) async {
    final mux = await guest();
    await fs.directory(cwd).create(recursive: true);
    return mux;
  }
}

/// What a run says while the guest is still coming up, which on a first
/// command is most of a minute.
const _booting = "Starting the Linux in this page…";

class _RunState {
  _RunState(this.timeout);

  final Duration timeout;
  bool interrupted = false;
  bool byTimeout = false;
  final List<String> chunks = [];
  final Completer<ShellResult> done = Completer();
  Timer? timeoutTimer;
  Timer? escalateTimer;

  String _emitted = "";
  String _held = "";
  bool watched = false;
  final ValueNotifier<String?> liveOutput = ValueNotifier(null);

  String tail(int length) {
    var out = "";
    for (var i = chunks.length - 1; i >= 0 && out.length < length; i--) {
      out = chunks[i] + out;
    }
    return out;
  }

  String get output => chunks.join("");

  void publish(String chunk, {required String marker}) {
    if (!watched) return;
    final joined = _held + chunk;
    _held = "";
    final cut = joined.lastIndexOf(_markerPrefix);
    String remainder;
    if (cut == -1) {
      remainder = joined;
    } else {
      _held = joined.substring(cut);
      remainder = joined.substring(0, cut);
    }
    if (remainder.isNotEmpty) {
      _emitted = _liveTail(_emitted, remainder.replaceAll(marker, ""));
    }
    liveOutput.value = _emitted.isEmpty ? null : _emitted;
  }

  void complete(ShellResult result) {
    timeoutTimer?.cancel();
    escalateTimer?.cancel();
    if (!done.isCompleted) done.complete(result);
  }
}

class _Session {
  _Session(this._shell, this._cwd, this._home) : _standing = _cwd;

  final GuestShell _shell;
  final String _cwd;
  final String _home;

  GuestProcess? _process;
  String? _fingerprint;
  String _marker = "";
  ByteConversionSink? _decoder;
  _RunState? _current;
  Future<void> _queue = Future.value();

  /// Where the shell stands, as its last sentinel said.
  String? _standing;

  ShellRun start(String command, Duration timeout,
      {Map<String, String>? environment, bool restart = false}) {
    final run = _SessionRun(_RunState(timeout), this);
    _queue = _queue.then((_) => _execute(run, command, timeout,
        environment: environment, restart: restart));
    return run;
  }

  Future<void> _execute(_SessionRun run, String command, Duration timeout,
      {Map<String, String>? environment, bool restart = false}) async {
    final state = run.state;
    if (state.done.isCompleted) return;
    final env = _shell._compose(_home, environment);
    final fingerprint = jsonEncode(env);
    if (restart || _fingerprint != fingerprint || _process == null) {
      if (state.watched) state.liveOutput.value = _booting;
      try {
        await _spawn(env, fingerprint);
      } catch (e) {
        state.complete(ShellResult.failed(
            "The Linux in this page could not start a shell: $e"));
        return;
      }
      if (state.watched) state.liveOutput.value = null;
    }
    if (state.done.isCompleted) return;
    final current = _current;
    if (current != null && !current.done.isCompleted) {
      _fail(ShellResult.failed(
          "The shell was interrupted by the next command.",
          output: current.output));
    }
    _current = state;
    state.timeoutTimer = Timer(timeout, () => _interrupt(state, byTimeout: true));
    _process!.write(utf8.encode("${base64.encode(utf8.encode(command))}\n"));
  }

  Future<void> _spawn(Map<String, String> env, String fingerprint) async {
    _teardown("The shell was restarted while the command was running.");
    final mux = await _shell._ready(_cwd);
    final token = const Uuid().v4();
    _marker = dispatcherMarker(token);
    final process = mux.start(["/bin/sh", "-c", dispatcherScript(token)],
        cwd: _cwd, environment: env);
    _process = process;
    _fingerprint = fingerprint;
    _standing = _cwd;
    _shell._cwds[_cwd]?.value = _cwd;
    final decoder = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(_ChunkSink(_onData));
    _decoder = decoder;
    process.output.listen(decoder.add, onDone: () {
      if (_process == process) _settleExit();
    });
    // A child it left behind can hold the output open past the shell's own
    // exit, so the exit, a grace later, settles it too.
    process.exitCode.then<void>(
      (_) => Timer(_drainGrace, () {
        if (_process == process) _settleExit();
      }),
      onError: (Object e) {
        if (_process != process) return;
        _fingerprint = null;
        _process = null;
        _fail(ShellResult.failed("The shell could not be started: $e"));
      },
    );
  }

  void _onData(String chunk) {
    final run = _current;
    if (run == null) return;
    run.chunks.add(chunk);
    run.publish(chunk, marker: _marker);
    if (!run.tail(_marker.length + 8).contains(_marker)) return;
    final buf = run.output;
    final start = buf.lastIndexOf("\n$_marker");
    if (start == -1) return;
    final end = buf.indexOf("@@\n", start);
    if (end == -1) return;
    final line = buf.substring(start + 1, end);
    final rcAt = line.indexOf(" rc=") + " rc=".length;
    final cwdAt = line.indexOf(" cwd=", rcAt);
    if (cwdAt == -1) return;
    final rc = int.tryParse(line.substring(rcAt, cwdAt));
    if (rc == null) return;
    run.chunks.clear();
    final cwd = line.substring(cwdAt + " cwd=".length);
    _current = null;
    _standing = cwd;
    _shell._cwds[_cwd]?.value = cwd;
    run.complete(ShellResult(
      returnCode: rc,
      output: buf.substring(0, start),
      cwd: cwd,
      exceptionInfo: run.interrupted
          ? run.byTimeout
              ? "The command timed out after ${_word(run.timeout)} and was "
                  "interrupted. Anything it printed before that is above."
              : "The command was interrupted."
          : null,
    ));
    // What a timeout's interrupt did not reach is still doing the timed-out
    // work; the group goes now, the shell coming back cold next command.
    if (run.byTimeout) _process?.signal(_sigkill);
  }

  /// The shell is gone: the run standing on it gets its answer, and the next
  /// command starts one again.
  void _settleExit() {
    final run = _current;
    _process = null;
    _fingerprint = null;
    _decoder?.close();
    _decoder = null;
    if (run != null) {
      _fail(ShellResult(
        returnCode: -1,
        output: run.output,
        exceptionInfo: run.interrupted
            ? run.byTimeout
                ? "The command timed out after ${_word(run.timeout)} and was "
                    "killed. Anything it printed before that is above."
                : "The command was interrupted and killed."
            : "The shell was closed while the command was running. "
                "It starts again, in its starting directory, on the next command.",
      ));
    }
    _standing = _cwd;
    _shell._cwds[_cwd]?.value = _cwd;
  }

  void _interrupt(_RunState run, {required bool byTimeout}) {
    if (run.interrupted) return;
    run.interrupted = true;
    run.byTimeout = byTimeout || run.byTimeout;
    final process = _process;
    if (process == null || _current != run) {
      // Not on the shell yet — still waiting on the guest or the queue — so
      // there is nothing to interrupt, and the run ends here.
      run.complete(ShellResult.failed(byTimeout
          ? "The command timed out after ${_word(run.timeout)} before it "
              "started."
          : "The command was interrupted before it started."));
      return;
    }
    process.signal(_sigint);
    run.escalateTimer = Timer(_grace, () {
      if (run.byTimeout || !run.done.isCompleted) _process?.signal(_sigkill);
    });
  }

  void _fail(ShellResult what) {
    final run = _current;
    _current = null;
    if (run != null) run.complete(what);
  }

  void _teardown(String why) {
    final run = _current;
    if (run != null) _fail(ShellResult.failed(why, output: run.output));
    final process = _process;
    _process = null;
    _fingerprint = null;
    _decoder = null;
    process?.signal(_sigkill);
  }

  void close() => _teardown("The shell was closed while the command was running.");
}

class _ChunkSink implements Sink<String> {
  _ChunkSink(this._onChunk);
  final void Function(String) _onChunk;
  @override
  void add(String chunk) => _onChunk(chunk);
  @override
  void close() {}
}

class _SessionRun implements ShellRun {
  _SessionRun(this.state, this._session);

  final _RunState state;
  final _Session _session;

  @override
  Future<ShellResult> get result => state.done.future;

  @override
  ValueListenable<String?>? get output {
    state.watched = true;
    return state.liveOutput;
  }

  @override
  Future<void> kill() async => _session._interrupt(state, byTimeout: false);
}

/// A sub-agent's command: a fresh `sh -c` in the guest, gone when it is.
class _OneShotRun implements ShellRun {
  _OneShotRun(this._shell, String script,
      {required String cwd,
      required String home,
      required this.timeout,
      Map<String, String>? environment}) {
    result = _run(script, cwd, _shell._compose(home, environment));
  }

  final GuestShell _shell;
  final Duration timeout;
  GuestProcess? _process;
  bool _killed = false;
  ValueNotifier<String?>? _notifier;
  String _emitted = "";

  @override
  late final Future<ShellResult> result;

  @override
  ValueListenable<String?>? get output =>
      _notifier ??= ValueNotifier<String?>(null);

  @override
  Future<void> kill() async {
    _killed = true;
    _process?.signal(_sigkill);
  }

  Future<ShellResult> _run(
      String script, String cwd, Map<String, String> env) async {
    final output = StringBuffer();
    Timer? timer;
    try {
      final mux = await _shell._ready(cwd);
      if (_killed) {
        return const ShellResult.failed("The command was interrupted.");
      }
      final process = mux.start(["/bin/sh", "-c", "exec 2>&1\n$script"],
          cwd: cwd, environment: env);
      _process = process;
      process.output.transform(const Utf8Decoder(allowMalformed: true)).listen(
          (chunk) {
        output.write(chunk);
        final notifier = _notifier;
        if (notifier == null) return;
        _emitted = _liveTail(_emitted, chunk);
        notifier.value = _emitted;
      });
      var timedOut = false;
      timer = Timer(timeout, () {
        timedOut = true;
        process.signal(_sigkill);
      });
      final code = await process.exitCode;
      await process.outputDone.timeout(_drainGrace, onTimeout: () {});
      final text = output.toString();
      if (!_killed && !timedOut) {
        return ShellResult(returnCode: code, output: text);
      }
      return ShellResult(
        returnCode: -1,
        output: text,
        exceptionInfo: _killed
            ? "The command was interrupted and killed."
            : "The command timed out after ${_word(timeout)} and was killed. "
                "Anything it printed before that is above.",
      );
    } catch (e) {
      logFailure("guest", "a one-shot command did not run", e);
      return ShellResult.failed(
          "An error occurred while executing the command: $e",
          output: output.toString());
    } finally {
      timer?.cancel();
    }
  }
}

class _Failed implements ShellRun {
  _Failed(String why) : result = Future.value(ShellResult.failed(why));

  @override
  final Future<ShellResult> result;

  @override
  ValueListenable<String?>? get output => null;

  @override
  Future<void> kill() async {}
}
