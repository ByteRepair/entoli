import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:uuid/uuid.dart";

import "../../domain/file_tools.dart";
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
    ShellDriver? Function({String? project})? driver,
  })  : _environment = environment ?? _none,
        _driver = driver ?? _hostDriver;

  /// What the commands run under, read at each command for the reason
  /// [_environment] is: installing a Linux from the settings page, or going
  /// back to the machine's own shell, reaches the next command rather than the
  /// next launch. Null is a machine with no shell at all, which is what a
  /// command sent to one reports. The project name reaches the driver so an
  /// isolated built-in can resolve its own rootfs instance.
  final ShellDriver? Function({String? project}) _driver;

  static ShellDriver? _hostDriver({String? project}) => hostDriver();

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
      List<String> command, String cwd, Map<String, String> env,
      {bool includeParentEnvironment = true}) async {
    // The cwd is a directory the app lays out, and it may not be there yet:
    // a project workspace before its first chat (a built-in project's setup
    // runs in one) or one a user deleted from the Files app. A missing
    // workingDirectory fails with ENOENT that names neither, so make it.
    Directory(cwd).createSync(recursive: true);
    final argv = command.skip(1).toList();
    if (_hasSetsid != false) {
      try {
        final process = await Process.start("setsid", [command.first, ...argv],
            workingDirectory: cwd,
            environment: env,
            includeParentEnvironment: includeParentEnvironment);
        _hasSetsid = true;
        return (process: process, ownsGroup: true);
      } on ProcessException {
        _hasSetsid = false;
      }
    }
    final process = await Process.start(command.first, argv,
        workingDirectory: cwd,
        environment: env,
        includeParentEnvironment: includeParentEnvironment);
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

  /// Where this shell reaches a guest or Android: the home is one directory
  /// every project would share, so a command gets the project workspace as
  /// its `HOME` and one project is one environment. On a desktop it is false,
  /// where the machine user's own `HOME` stands.
  @override
  bool get projectHome => _driver()?.projectHome ?? false;

  /// One expression, beside the shell that reads it: `io/platform.dart`'s
  /// `_home` composes the data and cache directories from the same answer.
  static String? machineHomeDir() =>
      Platform.environment["HOME"] ?? Platform.environment["USERPROFILE"];

  /// The machine user's own home directory; null where there is no real user
  /// home (the web, Android's app-private storage).
  @override
  String? get machineHome => machineHomeDir();

  /// What `HOME` is for a command here: the workspace the driver takes where
  /// it takes one, the machine user's own otherwise. One answer, so the
  /// prompt, the file tools and [composeEnvironment] cannot disagree.
  @override
  String? homeFor(String home) {
    final driver = _driver();
    return (driver?.projectHome ?? false)
        ? driver?.guestRoot ?? home
        : machineHome;
  }

  /// Where the project workspace appears inside the guest, or null on the
  /// machine itself. The file tools translate paths under it back to the
  /// host's, and the system prompt uses `~` in its place.
  @override
  String? get guestRoot => _driver()?.guestRoot;

  /// Host path prefixes mapped to their guest equivalents, for translating
  /// paths the model is told into the guest's vocabulary. Empty on the machine.
  @override
  Map<String, String> get hostToGuestPaths => _driver()?.hostToGuestPaths ?? const {};

  /// What commands run under on the machine itself: the shell [shellPath]
  /// resolved, whatever this build bundles beside it, and the sentence the
  /// model is told. Null where the machine has no shell at all, which is the
  /// browser's answer. [shell] answers for the machine where a test wants it
  /// to. [environment] is layered under the app's own settings the way a
  /// toolset's is — the one way a host driver names a directory its tools
  /// sit in.
  static ShellDriver? hostDriver({
    Toolset? tools,
    String? Function()? shell,
    bool projectHome = false,
    Map<String, String>? environment,
    SandboxHelper? sandboxHelper,
    String? loginPath,
  }) {
    final path = (shell ?? (() => shellPath))();
    if (path == null) return null;
    // The login shell's PATH is the base of the command environment, under
    // anything the caller layers on: a user-set `PATH` in the settings or a
    // project's bin directory still wins, which is the layering
    // [composeEnvironment] keeps.
    final environment0 = loginPath == null
        ? environment
        : {"PATH": loginPath, ...?environment};
    final where = "${Platform.operatingSystem} ${Platform.operatingSystemVersion}, "
        "commands run under $path";
    final bundled = tools?.names;
    if (bundled != null) {
      return _host(path, tools, "$where, with $bundled bundled with the app",
          projectHome: projectHome, environment: environment0,
          sandboxHelper: sandboxHelper);
    }
    final description = Platform.isAndroid && tools?.proot != null
        ? "$where. There is no git and no package manager here; installing "
            "a Linux from the Terminal settings gives you both"
        : where;
    return _host(path, tools, description,
        projectHome: projectHome, environment: environment0,
        sandboxHelper: sandboxHelper);
  }

  static ShellDriver _host(String path, Toolset? tools, String description,
          {bool projectHome = false, Map<String, String>? environment,
          SandboxHelper? sandboxHelper}) =>
      ShellDriver(
        commandFor: (_, _) => [path],
        environment: {...?environment, ...?tools?.environment},
        projectHome: projectHome,
        description: description,
        sandboxHelper: sandboxHelper,
      );

  @override
  SandboxHelper? get driverSandboxHelper {
    final helper = _driver()?.sandboxHelper;
    return helper;
  }

  @override
  String? tmpDirFor(String workspace) {
    // The chat workspace's own scratch directory: inside the granted set a
    // sandbox names, beside the files the command is there to touch. A
    // directory per chat rather than one shared tmp, so two chats' scratch
    // never meet.
    return Directory("$workspace/.entoli-tmp").path;
  }

  @override
  bool get platformIsWindows => Platform.isWindows;

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
      bool oneShot = false,
      bool restart = false,
      String? project,
      CommandSandbox? sandbox}) {
    // A sandboxed command runs in a confined subshell of its own, whatever
    // the caller asked for: the session shell is the conversation's shared
    // state, and a boundary asked for per command cannot be attached to it
    // and dropped for the next — a `cd` into the workspace would stand in a
    // shell whose exports, aliases and functions the next command inherits
    // unconfined. The confinement is per run, so the run is.
    final confined = sandbox != null || oneShot;
    if (confined) {
      final driver = _driver(project: project);
      return _OneShotRun(
        // The driver's shell, built for this chat's cwd and home, or nothing
        // where there is no driver at all.
        command: driver?.commandFor(cwd, home) ?? const [],
        script: command,
        cwd: cwd,
        timeout: timeout,
        environment: _compose(
            home: home, driver: driver, environment: environment),
        includeParentEnvironment: driver?.includeParentEnvironment ?? true,
        sandbox: sandbox,
        sandboxHelper: driver?.sandboxHelper,
      );
    }
    return _sessions
        .putIfAbsent(cwd, () => _Session(this, cwd, home, project: project))
        .start(command, timeout, environment: environment, restart: restart);
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
    required Map<String, String> app,
    Map<String, String>? project,
  }) =>
      {
        ...defaults,
        ...?driver?.environment,
        // The home is the workspace where the driver takes one — a guest's at
        // [guestRoot], not the host path — and the machine's own otherwise.
        if (driver?.projectHome ?? false) "HOME": driver?.guestRoot ?? home,
        ...app,
        ...?project,
      };

  Map<String, String> _compose({
    required String home,
    required ShellDriver? driver,
    Map<String, String>? environment,
  }) =>
      composeEnvironment(
        defaults: _defaults,
        driver: driver,
        home: home,
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

  /// What mini-swe-agent's own config sets: anything that would otherwise wait
  /// for a keypress or redraw a progress bar into the transcript. `BASH_ENV`
  /// is the empty one because a non-interactive shell sources it, and this
  /// shell answers to nothing but its queue.
  static const _defaults = {
    "PAGER": "cat",
    "MANPAGER": "cat",
    "GIT_PAGER": "cat",
    "LESS": "-R",
    "PIP_PROGRESS_BAR": "off",
    "TQDM_DISABLE": "1",
    "TERM": "dumb",
    "BASH_ENV": "",
  };
}

/// The dispatcher a persistent shell runs under. It reads the queue one line
/// at a time — a base64 command, nothing else can be in it — decodes it, and
/// evaluates it **in the shell itself**, so a `cd` or an `export` in it stands
/// when the line is done. The trailing line says what the command exited with
/// and where the shell is now, and is what Dart parses the run out of.
///
/// The `trap` is load-bearing: a non-interactive shell dies on the `SIGINT` a
/// stop sends, and a session that dies on every Ctrl-C is a one-shot shell
/// with extra steps. With it, the shell waits for the interrupted command to
/// go, reports its 130, and keeps whatever state it had.
///
/// The `EXIT` trap is the other end of that: a command that runs `exit` takes
/// the shell down with it, and the trap is what says how it went — the code
/// and the directory — before the pipe closes. Without it, an `exit 3` is a
/// dead shell with no answer.
///
/// The command's stdin is `/dev/null`, so nothing in it can drink the queue,
/// and its stderr is merged onto the stdout Dart reads, in order.
String _dispatcherScript(String token) => _dispatcherTemplate.replaceAll(
      "@TOKEN@",
      token,
    );

const _dispatcherTemplate = r"""
trap 'true' INT
trap 'printf "\n@@E@TOKEN@ rc=%s cwd=%s@@\n" "$?" "$(pwd)"' EXIT
while IFS= read -r line; do
  eval "$(printf '%s' "$line" | base64 -d)" </dev/null 2>&1
  printf '\n@@E@TOKEN@ rc=%s cwd=%s@@\n' "$?" "$(pwd)"
done
""";

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

/// How much of a running command's output the live view holds. A tail, not the
/// whole: the block on screen is the last of what has printed, and the final
/// result already carries the whole.
const _liveWindow = 8192;

/// The live tail after [piece] lands on [prior]: newlines dropped, bounded to
/// [_liveWindow]. What a running command's block shows; both run shapes keep
/// one.
String _liveTail(String prior, String piece) {
  var out = prior + piece.replaceAll("\n", "");
  if (out.length > _liveWindow) {
    out = out.substring(out.length - _liveWindow);
  }
  return out;
}

/// The head of the sentinel that ends a run, before the token. What the live
/// view holds back while it may still be forming — an `@@E` arriving with the
/// rest of its line in the next chunk is held, not shown, and published the
/// moment the next chunk proves it was ordinary output after all. The
/// sentinel proper is consumed by the parse before the watch can report it.
const _markerPrefix = "\n@@E";

/// One persistent shell: the process, its queue, and the run waiting on it.
/// Commands are written one at a time — a turn runs its commands in order and
/// only one turn runs in a chat at a time — so there is at most one run to
/// route the output to, and the queue is what keeps it that way even where a
/// stop and a resend land close together.
class _Session {
  _Session(this._shell, this._cwdPath, this._home, {this._project})
      : _displayCwd = _computeDisplayCwd(_shell, _cwdPath, _home);

  final LocalShell _shell;

  /// Where the shell starts, and what a respawn puts it back in.
  final String _cwdPath;

  /// The `HOME` the shell is given.
  final String _home;

  /// The project this session's chats belong to, so the driver can resolve a
  /// per-project rootfs instance for an isolated built-in. Constant for a
  /// session, since a session is keyed by the chat's cwd.
  final String? _project;

  /// The path the composer's cwd bar should show — the guest path where the
  /// shell runs inside one, the host path otherwise. Set once at construction,
  /// used in [_spawn] and [_settleExit] so the bar never flashes the host path.
  final String _displayCwd;

  static String _computeDisplayCwd(LocalShell shell, String cwd, String home) {
    final driver = shell._driver();
    final root = driver?.guestRoot;
    return root != null
        ? guestWorkspacePath(root, home, cwd)
        : cwd;
  }

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
       {Map<String, String>? environment, bool restart = false}) {
    final run = _SessionRun(_RunState(timeout), this);
    _queue = _queue.then((_) => _execute(run, command, timeout,
        environment: environment, restart: restart));
    return run;
  }

  Future<void> _execute(
    _SessionRun run,
    String command,
    Duration timeout, {
    Map<String, String>? environment,
    bool restart = false,
  }) async {
    final driver = _shell._driver(project: _project);
    final command0 = driver?.commandFor(_cwdPath, _home) ?? const [];
    if (command0.isEmpty) {
      run.state.complete(const ShellResult.failed(
          "No shell was found on this device to execute commands in."));
      return;
    }
    final env = _shell._compose(
        home: _home, driver: driver, environment: environment);
    final fp = _fingerprint(command0, env);
    if (restart || _fp != fp) {
      try {
        await _spawn(command0, env,
            includeParentEnvironment: driver?.includeParentEnvironment ?? true);
      } catch (e) {
        run.state.complete(
            ShellResult.failed("An error occurred while starting the shell: $e"));
        return;
      }
    }
    final process = _process;
    final state = run.state;
    // Fail a previous run that never completed before overwriting _current,
    // so its timers and interrupts don't become no-ops targeting a stale
    // reference. This happens when an abort's grace hasn't fired yet and the
    // next turn starts.
    if (_current != null && !_current!.done.isCompleted) {
      _failCurrent(ShellResult.failed(
          "The shell was interrupted by the next command.",
          output: _current!.output));
    }
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

  Future<void> _spawn(List<String> command, Map<String, String> env,
      {bool includeParentEnvironment = true}) async {
    await _teardown();
    final token = const Uuid().v4();
    _marker = "@@E$token rc=";
    final argv = [...command.skip(1), "-c", _dispatcherScript(token)];
    try {
      // `setsid` execs in place, so the pid it reports is the new group's —
      // which is what a stop kills. Whether it is there is learned by trying
      // it, the way the one-shot run learns it.
      final started = await LocalShell._spawnInGroup(
          [command.first, ...argv], _cwdPath, env,
          includeParentEnvironment: includeParentEnvironment);
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
    _shell._cwds[_cwdPath]?.value = _displayCwd;
  }

  void _onData(String chunk) {
    final run = _current;
    if (run == null) return;
    run.chunks.add(chunk);
    run.publish(chunk, marker: _marker);
    // The marker is short and can only be at the end, so the end is all that
    // is looked at; the whole is joined once, when a marker is found.
    if (!run.tail(_marker.length + 8).contains(_marker)) return;
    final buf = run.output;
    final start = buf.lastIndexOf("\n$_marker");
    if (start == -1) return;
    final end = buf.indexOf("@@\n", start);
    if (end == -1) return;
    // The full sentinel is present — safe to consume the buffer now. Calling
    // takeAll before this would lose data if the sentinel was split across two
    // _onData calls.
    run.chunks.clear();
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
    _shell._cwds[_cwdPath]?.value = _displayCwd;
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
    if (run.interrupted) return;
    run.interrupted = true;
    run.byTimeout = byTimeout || run.byTimeout;
    final process = _process;
    if (process != null) _signalGroup(process, _ownsGroup, ProcessSignal.sigint);
    run.escalateTimer = Timer(_grace, () {
      if (run.byTimeout || !run.done.isCompleted) _killGroup();
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

  /// What the live view of this run has been told so far, and the fragment
  /// where the sentinel may still be forming. Only the tail is kept: the whole
  /// output is in [chunks] and stays there for the final result.
  String _emitted = "";
  String _held = "";

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

  /// What the live view of this run says now: the tail of the output, with
  /// any fragment at its end that could be the sentinel's head held back
  /// until the next chunk settles what it was. Newlines are dropped here so
  /// the hold-back can search for `"\n@@E"` on what may still have them — the
  /// search runs before the strip, and the held fragment rides along to the
  /// next chunk rather than being published.
  ///
  /// Gated on [watched]: an output nobody reads pays nothing per chunk.
  /// Trimmed to [_liveWindow] from the head.
  void publish(String chunk, {required String marker}) {
    if (!watched) return;
    final joined = _held + chunk;
    _held = "";
    final cut = joined.lastIndexOf(_markerPrefix);
    String remainder;
    if (cut == -1) {
      remainder = joined;
    } else {
      _held = joined.substring(cut + 1); // the sentinel head has no newline
      remainder = joined.substring(0, cut);
    }
    if (remainder.isNotEmpty) {
      _emitted = _liveTail(_emitted, remainder.replaceAll(marker, ""));
    }
    liveOutput.value = _emitted.isEmpty ? null : _emitted;
  }

  /// Whether anyone is reading [liveOutput]. A run nobody watches — a
  /// sub-agent's, any run before a watch lands — keeps publishing off.
  bool watched = false;

  /// Where each live update is read from. Created with the run.
  final ValueNotifier<String?> liveOutput = ValueNotifier(null);

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
  ValueListenable<String?>? get output {
    // Asking is the watch: before this the session's chunks pay nothing for a
    // view nobody reads.
    state.watched = true;
    return state.liveOutput;
  }

  @override
  Future<void> kill() async {
    _session._interrupt(state, byTimeout: false);
  }
}

/// The failure a one-shot run's spawn carries when a sandbox was asked for
/// and could not be built. Thrown rather than returned so [result] completes
/// as a failed command through the same catch a spawn error takes.
class ShellUnavailable implements Exception {
  const ShellUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The line a refused write prints: either the shell's own (`sh: /path:
/// Permission denied`) or the tool's (`tool: cannot open '/path' for
/// writing: Permission denied`). A build's errors are the model's only
/// report of what the sandbox took away, so both wordings are matched.
final RegExp deniedPathPattern = RegExp(
    r"""(?:^|[\s:"'(])(?:(?:cannot (?:open|touch|create regular file|create) )?|[\s:"(])'?(/[\w.@+/ -]*?)'?(?:\s*for writing)?(?:\s*in)?\s*: (?:Permission denied|Read-only file system)""",
    multiLine: true);

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
    this.includeParentEnvironment = true,
    this.sandbox,
    this.sandboxHelper,
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
  final bool includeParentEnvironment;

  /// The confinement this one command runs under, with the helper that
  /// applies it. Both null where there is nothing to apply — the common case,
  /// and the only one a platform without confinement is ever handed.
  final CommandSandbox? sandbox;
  final SandboxHelper? sandboxHelper;

  @override
  late final Future<ShellResult> result;

  Process? _process;
  bool _ownsGroup = false;
  bool _killed = false;

  /// The live tail of the output, created by the first read of [output] and
  /// kept by [_run]'s read loop only from then on — a one-shot run is a
  /// sub-agent's command, and nobody asks for its output today.
  ValueNotifier<String?>? _notifier;

  String? _emitted;

  @override
  ValueListenable<String?>? get output =>
      _notifier ??= ValueNotifier<String?>(null);

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
          .listen((chunk) {
        output.write(chunk);
        _publish(chunk);
      });
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
          violations: _violations(output.toString()),
        );
      }
      if (timer.isActive) {
        return ShellResult(returnCode: code, output: output.toString(),
            violations: _violations(output.toString()));
      }
      return ShellResult(
        returnCode: -1,
        output: output.toString(),
        exceptionInfo: "The command timed out after ${timeout.inSeconds}s and was killed. "
            "Anything it printed before that is above.",
        violations: _violations(output.toString()),
      );
    } on ShellUnavailable catch (e) {
      // Fail-closed has its own words: a confinement that did not happen is
      // not a spawn error, and the reason is what the model rewrites around.
      return ShellResult.failed(e.message, output: output.toString());
    } catch (e) {
      return ShellResult.failed(
        "An error occurred while executing the command: $e",
        output: output.toString(),
      );
    } finally {
      timer?.cancel();
    }
  }

  /// What the confinement denied, read out of the command's own output: a
  /// write the kernel refused prints its EACCES, and the line names the path.
  /// Only lines naming a path outside what the sandbox granted are collected
  /// — a permission error on a workspace file is the command's own business,
  /// not the sandbox's — and the count is capped, so one bad loop cannot
  /// bury the tool result in copies of the same refusal.
  List<String> _violations(String text) {
    if (sandbox == null) return const [];
    final workspace = sandbox!.workspace;
    final tmp = sandbox!.tmp;
    final found = <String>{};
    final write = <String>{};
    for (final match in deniedPathPattern.allMatches(text)) {
      final path = match.group(1);
      if (path == null || path.isEmpty) continue;
      if (pathInside(path, workspace) || tmp != null && pathInside(path, tmp)) {
        continue;
      }
      if (path == "/dev/null") continue;
      found.add(path);
      // Only the line's own words say this was a write: `cannot touch`,
      // `cannot create`, `for writing`. A plain `sh: /path: Permission
      // denied` is a refused redirect, but a `cat` denied by the file's own
      // Unix perms prints the same shape — and this sandbox grants every
      // read, so a line without the tool's write words is worded neutrally
      // rather than reported as a write it may not have been.
      final line = match.group(0)!;
      if (line.contains("cannot ") || line.contains("for writing")) {
        write.add(path);
      }
      if (found.length >= 5) break;
    }
    return [for (final path in found) write.contains(path) ? "writing $path" : "denied $path"];
  }

  /// `exec 2>&1` redirects the shell's own error output and everything it goes
  /// on to spawn, which is what makes the transcript read in order.
  ///
  /// Whether `setsid` exists is learned by trying it rather than by probing
  /// first: a failed spawn says the same thing without costing a subprocess.
  Future<Process> _spawn() async {
    var argv = [...command.skip(1), "-c", "exec 2>&1\n$script"];
    var head = command.first;
    // The sandboxed shape: the helper's prefix goes ahead of the shell, so
    // the subshell and everything it execs is confined from its first
    // instruction. A sandbox asked for and not built is a command not run —
    // the same fail-closed answer the session path gives.
    var confined = environment;
    if (sandbox != null) {
      final prefix =
          sandboxHelper == null ? null : await sandboxHelper!.prefixFor(sandbox!);
      if (prefix == null) {
        throw const ShellUnavailable("No sandbox is available on this machine "
            "to run this command confined, so it was not run. Landlock needs "
            "Linux 5.13 or newer and a C compiler.");
      }
      // The helper refuses a grant to a directory that is not there, so the
      // tmp the ruleset names is made before the spawn. It is inside the
      // workspace, so making it costs nothing the sandbox has not already
      // granted.
      final tmp = sandbox!.tmp;
      if (tmp != null) {
        Directory(tmp).createSync(recursive: true);
        confined = {...environment, "TMPDIR": tmp};
      }
      // The helper's prefix, then the driver's whole shell argv: the shell is
      // confined from its first instruction and `-c` with the script goes on
      // the end of it, the shape the helper's usage line takes.
      head = prefix.first;
      argv = [...prefix.skip(1), ...command, "-c", "exec 2>&1\n$script"];
    }
    final started = await LocalShell._spawnInGroup(
        [head, ...argv], cwd, confined,
        includeParentEnvironment: includeParentEnvironment);
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

  /// The one-shot run has no sentinel — the subshell is gone when the command
  /// is — so what reaches the live view is [_liveTail]'s answer alone. A run
  /// nobody reads has no notifier and keeps nothing per chunk.
  void _publish(String chunk) {
    final notifier = _notifier;
    if (notifier == null) return;
    _emitted = _liveTail(_emitted ?? "", chunk);
    notifier.value = _emitted;
  }
}
