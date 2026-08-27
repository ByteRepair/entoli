import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:uuid/uuid.dart";

import "../../domain/shell.dart";

/// Runs commands where the [ShellDriver] it is given says they run: the
/// machine's own shell by default, a downloaded Linux under proot where the
/// user has picked one, or — when one is built — an emulator or a container.
/// To the session machinery below every one of them is the same thing, a
/// command that ends in a shell, and that is the whole of what a new driver
/// owes it.
///
/// The chat's commands run in a **persistent shell, one per chat**: a single
/// non-interactive process whose state — the directory a `cd` moved it to, the
/// variables an export gave it — carries over from one command to the next,
/// and which the agent's `bash` calls and the user's `!` commands share. The
/// agent is told the contract in its prompt, and a command that moves the
/// directory leaves a note in its own result.
///
/// Each command crosses the wire as one base64 line — the raw script never
/// touches the session's stdin, so a multi-line command, a quote, or a
/// `read` in it cannot steal the next line of the queue. The line is evaluated
/// in the session's own shell, which is what makes a `cd` in it stick.
///
/// Stopping a command is a `SIGINT` to the group — a Ctrl-C, not a murder:
/// the session's shell traps the signal and keeps its state, the command dies
/// with a 130, and a command that ignores the interrupt is killed for real
/// after a grace, with the shell respawning cold on the next command. A
/// timeout's kill lands earlier still — the moment the command's own sentinel
/// comes, since what survives the interrupt ignores it and the grace cannot
/// reach any sooner.
///
/// Sub-agents run under [Shell.start]'s [Shell.start.oneShot] instead: a
/// fresh subshell per command, no state, no sharing — a fan-out of workers
/// that needs concurrency rather than a terminal.
class LocalShell extends Shell {
  LocalShell({
    Map<String, String> Function()? environment,
    ShellDriver? Function()? driver,
  })  : _environment = environment ?? _none,
        _driver = driver ?? _hostDriver;

  /// What the commands run under, read at each command for the reason
  /// [_environment] is: installing a Linux from the settings page, or going
  /// back to the machine's own shell, reaches the next command rather than the
  /// next launch. Null is a machine with no shell at all, which is what a
  /// command sent to one reports.
  final ShellDriver? Function() _driver;

  static ShellDriver? _hostDriver() => hostDriver();

  /// Applied over the process's own environment. Read at each command rather
  /// than captured, so a variable added in settings reaches the next one.
  final Map<String, String> Function() _environment;

  static Map<String, String> _none() => const {};

  /// Set once we know whether `setsid` is on this machine. Without it a
  /// timeout can only kill the shell, leaving whatever it spawned running.
  static bool? _hasSetsid;

  /// Start a process in its own session where `setsid` is there to make one,
  /// learning by trying it rather than by probing first: a failed spawn says
  /// the same thing without costing a subprocess. Returns the process and
  /// whether it owns a process group a stop can kill.
  static Future<({Process process, bool ownsGroup})> _spawnInGroup(
      List<String> command, String cwd, Map<String, String> env) async {
    final argv = command.skip(1).toList();
    if (_hasSetsid != false) {
      try {
        final process = await Process.start("setsid", [command.first, ...argv],
            workingDirectory: cwd, environment: env);
        _hasSetsid = true;
        return (process: process, ownsGroup: true);
      } on ProcessException {
        _hasSetsid = false;
      }
    }
    final process = await Process.start(command.first, argv,
        workingDirectory: cwd, environment: env);
    return (process: process, ownsGroup: false);
  }

  /// One persistent shell per chat, keyed by the directory it starts in —
  /// which is the chat's own, so it is unique to the chat.
  final Map<String, _Session> _sessions = {};

  /// Where each session is standing, for the composer's bar. Created on first
  /// ask, held for the life of the shell, and seeded with the directory the
  /// shell starts in.
  final Map<String, ValueNotifier<String?>> _cwds = {};

  @override
  String get platformDescription {
    final driver = _driver();
    if (driver != null) return driver.description;
    return "${Platform.operatingSystem} ${Platform.operatingSystemVersion}, "
        "commands run under no shell";
  }

  /// False where there is no shell to offer at all. Android is why this is
  /// not a constant: it has no `/bin` at all, and a device whose `PATH` turns
  /// up nothing is one where every command would otherwise fail one at a time.
  /// A guest brings its own shell, so it answers for itself.
  @override
  bool get canRunCommands => _driver() != null;

  /// Where this shell reaches a guest: the guest's home is one directory
  /// every project would share, so a command gets the project workspace as
  /// its `HOME` and one project is one environment. On the machine itself it
  /// is false, where a turn's `sharedHome` answers for the home instead.
  @override
  bool get projectHome => _driver()?.projectHome ?? false;

  /// What commands run under on the machine itself: the shell [shellPath]
  /// resolved, whatever this build bundles beside it, and the sentence the
  /// model is told. Null where the machine has no shell at all, which is the
  /// browser's answer. [shell] answers for the machine where a test wants it
  /// to.
  static ShellDriver? hostDriver({
    Toolset? tools,
    String? Function()? shell,
  }) {
    final path = (shell ?? (() => shellPath))();
    if (path == null) return null;
    final where = "${Platform.operatingSystem} ${Platform.operatingSystemVersion}, "
        "commands run under $path";
    final bundled = tools?.names;
    if (bundled != null) {
      return _host(path, tools, "$where, with $bundled bundled with the app");
    }
    // Android's shell is toybox and nothing else — no git, and no way to add
    // one outside a guest. Said rather than left to be discovered, since the
    // alternative is the model working around the absence one `command not
    // found` at a time.
    final description = Platform.isAndroid && tools?.proot != null
        ? "$where. There is no git and no package manager here; installing "
            "a Linux from the Terminal settings gives you both"
        : where;
    return _host(path, tools, description);
  }

  static ShellDriver _host(String path, Toolset? tools, String description) =>
      ShellDriver(
        command: [path],
        environment: tools?.environment ?? const {},
        projectHome: false,
        description: description,
      );

  @override
  ValueListenable<String?>? sessionCwd(String cwd) {
    if (!canRunCommands) return null;
    return _cwds.putIfAbsent(cwd, () => ValueNotifier<String?>(cwd));
  }

  @override
  void closeSession(String cwd) {
    _cwds.remove(cwd)?.dispose();
    _sessions.remove(cwd)?.close();
  }

  @override
  ShellRun start(String command,
      {required String cwd,
      required String home,
      required Duration timeout,
      Map<String, String>? environment,
      bool sharedHome = true,
      bool oneShot = false,
      bool restart = false}) {
    final driver = _driver();
    if (oneShot) {
      return _OneShotRun(
        // The driver's shell, and whatever stands between it and the machine,
        // or nothing where there is no driver at all.
        command: driver?.command ?? const [],
        script: command,
        cwd: cwd,
        timeout: timeout,
        environment: _compose(
            home: home,
            driver: driver,
            sharedHome: sharedHome,
            environment: environment),
      );
    }
    return _sessions
        .putIfAbsent(cwd, () => _Session(this, cwd, home))
        .start(command, timeout,
            environment: environment,
            sharedHome: sharedHome,
            restart: restart);
  }

  /// What a command runs under, with the layers in the order they win. The
  /// driver's environment is what the shell starts with — a guest's, where the
  /// driver is one that reaches a guest, where a host `PATH` names directories
  /// that are not there — and the app's variables over it, so a variable the
  /// user set wins, `PATH` being the one they are likely to disagree about,
  /// and a project's over the app's.
  @visibleForTesting
  static Map<String, String> composeEnvironment({
    required Map<String, String> defaults,
    ShellDriver? driver,
    required String home,
    required bool sharedHome,
    required Map<String, String> app,
    Map<String, String>? project,
  }) =>
      {
        ...defaults,
        ...?driver?.environment,
        // The guest's `/root` is one directory every project would share,
        // and a home that is not shared is the chat's own: both take
        // [home]. Where the home is shared on a machine, the machine's own
        // `HOME` stands.
        if ((driver?.projectHome ?? false) || !sharedHome) "HOME": home,
        ...app,
        ...?project,
      };

  Map<String, String> _compose({
    required String home,
    required ShellDriver? driver,
    required bool sharedHome,
    Map<String, String>? environment,
  }) =>
      composeEnvironment(
        defaults: _defaults,
        driver: driver,
        home: home,
        sharedHome: sharedHome,
        app: _environment(),
        project: environment,
      );

  /// The shell every command is run under, resolved once. `bash` is preferred
  /// because the prompt's examples are written for it, and the fallbacks are
  /// the two places a shell sits that `PATH` may not name: a stripped
  /// environment on the desktops, and Android, where it is `/system/bin`.
  static final String? shellPath = resolveShell();

  @visibleForTesting
  static String? resolveShell({String? path, bool Function(String)? isExecutable}) {
    final executable = isExecutable ?? _executable;
    final dirs = (path ?? Platform.environment["PATH"] ?? "")
        .split(Platform.isWindows ? ";" : ":");
    for (final name in const ["bash", "sh"]) {
      for (final dir in dirs) {
        if (dir.isEmpty) continue;
        final candidate = "$dir${Platform.pathSeparator}$name";
        if (executable(candidate)) return candidate;
      }
    }
    for (final candidate in _fallbacks) {
      if (executable(candidate)) return candidate;
    }
    return null;
  }

  static const _fallbacks = ["/bin/bash", "/system/bin/sh", "/bin/sh"];

  /// Windows reports no mode bits, so there the file being there is the whole
  /// of the test.
  static bool _executable(String path) {
    final stat = FileStat.statSync(path);
    if (stat.type != FileSystemEntityType.file) return false;
    return Platform.isWindows || stat.mode & _anyExecuteBit != 0;
  }

  /// `0o111`: executable by anyone at all, which is as much as this can ask
  /// without knowing which of the three the app is running as.
  static const _anyExecuteBit = 0x49;

  static const _defaults = defaultShellEnvironment;
}

/// The dispatcher the persistent shell runs under lives in `domain/shell.dart`
/// now, shared with `IshShell`: the contract — a Ctrl-C the shell traps into a
/// 130 while keeping its state, an `EXIT` trap that reports where the shell
/// died, and a base64 line that keeps a multi-line command from stealing the
/// queue — is the same whether the shell is a child process or an emulated
/// guest. See `dispatcherScript` there.

/// What the flush of a pipe whose writers have gone is worth waiting for. A
/// command that left one holding it pays this in full, once.
const _drainGrace = Duration(seconds: 2);

/// Signal a process's group where one was made, falling back to the process
/// itself. A group kill is preferred so a timed-out `npm install` that only
/// loses its shell does not keep downloading; the fallback is for a platform
/// whose `setsid` was not there to make a group at all.
void _signalGroup(Process process, bool ownsGroup, ProcessSignal signal) {
  if (ownsGroup) {
    try {
      if (Process.killPid(-process.pid, signal)) return;
    } catch (_) {}
  }
  process.kill(signal);
}

/// One persistent shell: the process, its queue, and the run waiting on it.
/// Commands are written one at a time — a turn runs its commands in order and
/// only one turn runs in a chat at a time — so there is at most one run to
/// route the output to, and the queue is what keeps it that way even where a
/// stop and a resend land close together.
class _Session {
  _Session(this._shell, this._cwdPath, this._home);

  final LocalShell _shell;

  /// Where the shell starts, and what a respawn puts it back in.
  final String _cwdPath;

  /// The `HOME` the shell is given.
  final String _home;

  Process? _process;
  bool _ownsGroup = false;

  /// What the shell was spawned with. A command whose answer differs — a
  /// variable added in settings, a Linux installed or deleted — respawns the
  /// shell cold, which is how the change reaches the next command rather than
  /// the next launch.
  String? _fp;

  /// The marker a run waits for, unique to this shell's life so a command's
  /// output cannot forge it.
  String _marker = "";

  StreamSubscription<String>? _sub;
  Utf8Decoder? _decoder;

  _RunState? _current;

  /// The FIFO. Each command waits its turn, and whatever the wait is — a
  /// respawn, a wedged predecessor — it happens before the line is written.
  Future<void> _queue = Future.value();

  /// How long a stop or a timeout waits on the interrupt before killing.
  static const _grace = Duration(seconds: 1);

  ShellRun start(String command, Duration timeout,
       {Map<String, String>? environment,
       bool sharedHome = true,
       bool restart = false}) {
    final run = _SessionRun(_RunState(timeout), this);
    _queue = _queue.then((_) =>
        _execute(run, command, timeout,
            environment: environment,
            sharedHome: sharedHome,
            restart: restart));
    return run;
  }

  Future<void> _execute(
    _SessionRun run,
    String command,
    Duration timeout, {
    Map<String, String>? environment,
    bool sharedHome = true,
    bool restart = false,
  }) async {
    final driver = _shell._driver();
    final command0 = driver?.command ?? const [];
    if (command0.isEmpty) {
      run.state.complete(const ShellResult.failed(
          "No shell was found on this device to execute commands in."));
      return;
    }
    final env = _shell._compose(
        home: _home,
        driver: driver,
        sharedHome: sharedHome,
        environment: environment);
    final fp = _fingerprint(command0, env);
    if (restart || _fp != fp) {
      try {
        await _spawn(command0, env);
      } catch (e) {
        run.state.complete(
            ShellResult.failed("An error occurred while starting the shell: $e"));
        return;
      }
    }
    final process = _process;
    final state = run.state;
    _current = state;
    state.timeoutTimer = Timer(timeout, () => _interrupt(state, byTimeout: true));
    try {
      // The whole of the wire protocol: one base64 line, decoded and
      // evaluated by the shell.
      process!.stdin.write("${base64.encode(utf8.encode(command))}\n");
      await process.stdin.flush();
    } catch (e) {
      // A write that fails is a pipe whose other end is gone: the shell is
      // dead, and the next command starts one again.
      _failCurrent(ShellResult.failed(
          "An error occurred while executing the command: $e",
          output: state.output));
    }
  }

  /// What says the shell this is, so a change to any of it respawns it.
  static String _fingerprint(List<String> command, Map<String, String> env) =>
      "${command.join("\u0000")}\u0000${env.entries.map((e) => "${e.key}=${e.value}").join("\u0000")}";

  Future<void> _spawn(List<String> command, Map<String, String> env) async {
    await _teardown();
    final token = const Uuid().v4();
    _marker = dispatcherMarker(token);
    final argv = [...command.skip(1), "-c", dispatcherScript(token)];
    try {
      // `setsid` execs in place, so the pid it reports is the new group's —
      // which is what a stop kills. Whether it is there is learned by trying
      // it, the way the one-shot run learns it.
      final started = await LocalShell._spawnInGroup(
          [command.first, ...argv], _cwdPath, env);
      _process = started.process;
      _ownsGroup = started.ownsGroup;
    } catch (e) {
      _process = null;
      throw ProcessException(command.first, argv, "$e");
    }
    _fp = _fingerprint(command, env);
    final process = _process!;
    _decoder = const Utf8Decoder(allowMalformed: true);
    _sub = process.stdout
        .transform(_decoder!)
        .listen(_onData, onDone: _settleExit);
    // The pipe outlives the process while an escaped child holds it, so the
    // exit code is the faster report of the shell being gone — and the grace
    // is what settles a run the pipe then never closes.
    unawaited(process.exitCode.then((_) =>
        Timer(_drainGrace, () {
          if (_process == process) _settleExit();
        })));
    // A fresh shell is standing where it was told to start.
    _shell._cwds[_cwdPath]?.value = _cwdPath;
  }

  void _onData(String chunk) {
    final run = _current;
    if (run == null) return;
    run.chunks.add(chunk);
    // The marker is short and can only be at the end, so the end is all that
    // is looked at; the whole is joined once, when a marker is found.
    if (!run.tail(_marker.length + 8).contains(_marker)) return;
    final buf = run.takeAll();
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
    final output = buf.substring(0, start);
    final cwd = line.substring(cwdAt + " cwd=".length);
    _current = null;
    run.timeoutTimer?.cancel();
    _shell._cwds[_cwdPath]?.value = cwd;
    run.complete(ShellResult(
      returnCode: rc,
      output: output,
      cwd: cwd,
      exceptionInfo: run.interrupted
          ? run.byTimeout
              ? "The command timed out after ${run.timeout.inSeconds}s and was "
                  "interrupted. Anything it printed before that is above."
              : "The command was interrupted."
          : null,
    ));
    // A timeout's escalation lands here rather than at the end of the grace:
    // the command is done, so the interrupt is spent, and whatever survived
    // it — the background a non-interactive shell starts ignores the
    // interrupt — is still doing the timed-out work. The grace cannot reach
    // it sooner, so the group goes now, shell with it, coming back cold on
    // the next command the way the escalation would have.
    if (run.byTimeout) {
      run.escalateTimer?.cancel();
      _killGroup();
    }
  }

  /// The shell is gone — the process exited, a command in it ran `exit`, or
  /// a stop escalated. Whatever run was waiting on it gets its answer now,
  /// and the shell comes back cold on the next command. Called from the pipe
  /// closing and, a grace later, from the process's exit; whichever comes
  /// first settles, and the other finds nothing to do.
  void _settleExit() {
    final run = _current;
    if (run != null) {
      _failCurrent(ShellResult(
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
    _shell._cwds[_cwdPath]?.value = _cwdPath;
  }

  /// How the timeout is worded in an answer.
  static String _word(Duration d) =>
      d.inMilliseconds < 1000 ? "${d.inMilliseconds}ms" : "${d.inSeconds}s";

  /// A stop, or a timeout: a `SIGINT` to the group, which is the Ctrl-C the
  /// session's trap turns into "the command is gone, the shell is not". A
  /// grace follows the signal, past which the group is killed for real.
  ///
  /// A stop escalates only when it went unanswered — a command that ignores
  /// the interrupt keeps the shell waiting on it, and a wedged shell has to
  /// come back cold on the next command. A timeout escalates whichever way —
  /// at the command's own sentinel, where the interrupt is spent and only
  /// what ignores the interrupt is left (a non-interactive shell's background
  /// ignores it, and a timed-out `npm install` that only lost its shell keeps
  /// downloading), or at the end of the grace where the command never
  /// answered at all.
  void _interrupt(_RunState run, {required bool byTimeout}) {
    if (run.interrupted || _current != run) return;
    run.interrupted = true;
    run.byTimeout = byTimeout || run.byTimeout;
    final process = _process;
    if (process != null) _signalGroup(process, _ownsGroup, ProcessSignal.sigint);
    run.escalateTimer = Timer(_grace, () {
      if (run.byTimeout || _current == run) _killGroup();
    });
  }

  void _killGroup() {
    final process = _process;
    if (process == null) return;
    _signalGroup(process, _ownsGroup, ProcessSignal.sigkill);
  }

  /// The shell is gone, and [what] is the answer the run standing on its line
  /// gets: whatever the cause — the process exited, a restart tore it down,
  /// or the line could not be written — the settling is one. The fingerprint
  /// goes with it, so the next command starts a shell again.
  void _failCurrent(ShellResult what) {
    _fp = null;
    final run = _current;
    _current = null;
    if (run != null && !run.done.isCompleted) {
      run.timeoutTimer?.cancel();
      run.escalateTimer?.cancel();
      run.complete(what);
    }
  }

  /// Take the shell down: the run it was serving, the pipe, and the group.
  Future<void> _teardown() async {
    final run = _current;
    if (run != null) {
      _failCurrent(ShellResult.failed(
          "The shell was restarted while the command was running.",
          output: run.output));
    }
    final process = _process;
    final ownsGroup = _ownsGroup;
    _process = null;
    _ownsGroup = false;
    await _sub?.cancel();
    _sub = null;
    if (process != null) _signalGroup(process, ownsGroup, ProcessSignal.sigkill);
  }

  /// For when the chat the shell belongs to is deleted.
  Future<void> close() => _teardown();
}

class _RunState {
  _RunState(this.timeout);

  final Duration timeout;
  bool interrupted = false;
  bool byTimeout = false;
  final List<String> chunks = [];
  final Completer<ShellResult> done = Completer();

  /// The last [length] of what has come in, without joining the lot.
  String tail(int length) {
    var out = "";
    for (var i = chunks.length - 1; i >= 0 && out.length < length; i--) {
      out = chunks[i] + out;
    }
    return out;
  }

  /// The whole, joined and emptied — called once, when the run is over.
  String takeAll() {
    final out = chunks.join("");
    chunks.clear();
    return out;
  }

  String get output => chunks.join("");

  /// Guarded: a stop, a close and the sentinel all race for the same run.
  void complete(ShellResult result) {
    if (!done.isCompleted) done.complete(result);
  }

  Timer? timeoutTimer;
  Timer? escalateTimer;
}

class _SessionRun implements ShellRun {
  _SessionRun(this.state, this._session);

  final _RunState state;
  final _Session _session;

  @override
  Future<ShellResult> get result => state.done.future;

  @override
  Future<void> kill() async {
    _session._interrupt(state, byTimeout: false);
  }
}

/// What a `oneShot` command is: today's contract, a fresh subshell per
/// command, kept for sub-agents and for the platforms a persistent shell
/// would only complicate.
class _OneShotRun implements ShellRun {
  _OneShotRun({
    required this.command,
    required this.script,
    required this.cwd,
    required this.timeout,
    required this.environment,
  }) {
    result = _run();
  }

  /// What to run, ending in a shell. `-c` and the script go on the end of it,
  /// so a guest's shell reached through proot and the machine's own are the
  /// same thing to everything below here.
  final List<String> command;

  final String script;
  final String cwd;
  final Duration timeout;
  final Map<String, String> environment;

  @override
  late final Future<ShellResult> result;

  Process? _process;
  bool _ownsGroup = false;
  bool _killed = false;

  @override
  Future<void> kill() async {
    _killed = true;
    _killTree();
  }

  Future<ShellResult> _run() async {
    if (command.isEmpty) {
      return const ShellResult.failed(
          "No shell was found on this device to execute commands in.");
    }
    final output = StringBuffer();
    Timer? timer;
    try {
      _process = await _spawn();
      final process = _process!;
      // Merged in the shell rather than here: two Dart streams arrive in
      // whatever order the pipes flush, and a compiler's errors interleaved
      // with its progress is the whole value of reading them.
      final reading = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(output.write);
      // Asked for here rather than below: `asFuture` replaces the done handler,
      // so one asked for after the pipe has closed never completes at all.
      final drained = reading.asFuture<void>();

      timer = Timer(timeout, _killTree);
      final code = await process.exitCode;
      // A child in a session of its own goes on holding stdout after the group
      // is killed, so waiting for the rest of it has to be bounded.
      await drained.timeout(_drainGrace, onTimeout: () {});
      await reading.cancel();
      if (_killed) {
        return ShellResult(
          returnCode: -1,
          output: output.toString(),
          exceptionInfo: "The command was interrupted and killed.",
        );
      }
      if (timer.isActive) return ShellResult(returnCode: code, output: output.toString());
      return ShellResult(
        returnCode: -1,
        output: output.toString(),
        exceptionInfo: "The command timed out after ${timeout.inSeconds}s and was killed. "
            "Anything it printed before that is above.",
      );
    } catch (e) {
      return ShellResult.failed(
        "An error occurred while executing the command: $e",
        output: output.toString(),
      );
    } finally {
      timer?.cancel();
    }
  }

  /// `exec 2>&1` redirects the shell's own error output and everything it goes
  /// on to spawn, which is what makes the transcript read in order.
  ///
  /// Whether `setsid` exists is learned by trying it rather than by probing
  /// first: a failed spawn says the same thing without costing a subprocess.
  Future<Process> _spawn() async {
    final argv = [...command.skip(1), "-c", "exec 2>&1\n$script"];
    final started = await LocalShell._spawnInGroup([command.first, ...argv], cwd, environment);
    _ownsGroup = started.ownsGroup;
    return started.process;
  }

  /// Kill the whole process group where we made one: a timed-out `npm install`
  /// that only loses its shell keeps downloading.
  void _killTree() {
    final process = _process;
    if (process == null) return;
    _signalGroup(process, _ownsGroup, ProcessSignal.sigkill);
  }
}
