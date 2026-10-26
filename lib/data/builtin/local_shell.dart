import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;
import "package:uuid/uuid.dart";

import "../../core/log.dart";
import "../../domain/file_tools.dart";
import "../../domain/shell.dart";

const _appImageVars = {"APPIMAGE", "APPDIR", "ARGV0", "OWD"};

/// This process's environment without the AppImage runtime's variables, which
/// describe this app rather than what it starts: a command inheriting
/// `APPDIR` or `ARGV0` misreads both, and Helium's own AppImage would read
/// ours as its own. Dart cannot unset an inherited variable, so the rest is
/// copied.
Map<String, String> environmentWithoutAppImage() => {
      for (final e in Platform.environment.entries)
        if (!_appImageVars.contains(e.key)) e.key: e.value,
    };

/// Runs commands under the [ShellDriver] it is given, in one persistent shell
/// per chat; a sandboxed or `oneShot` command gets a fresh subshell. See
/// "Running the commands" in `lib/data/builtin/AGENTS.md`.
class LocalShell extends Shell {
  LocalShell({
    Map<String, String> Function()? environment,
    ShellDriver? Function({String? project})? driver,
  })  : _environment = environment ?? (() => const {}),
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
    if (includeParentEnvironment &&
        _appImageVars.any(Platform.environment.containsKey)) {
      env = {...environmentWithoutAppImage(), ...env};
      includeParentEnvironment = false;
    }
    if (_hasSetsid != false && !Platform.isWindows) {
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

  @override
  bool get canRunInBackground => canRunCommands;

  /// Where this shell reaches a guest or Android: the home is one directory
  /// every project would share, so a command gets the project workspace as
  /// its `HOME` and one project is one environment. On a desktop it is false,
  /// where the machine user's own `HOME` stands.
  @override
  bool get projectHome => _driver()?.projectHome ?? false;

  /// One expression, beside the shell that reads it: `io/platform.dart`'s
  /// `_home` composes the data and cache directories from the same answer.
  static String? machineHomeDir() => Platform.isWindows
      ? Platform.environment["USERPROFILE"] ?? Platform.environment["HOME"]
      : Platform.environment["HOME"];

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
    final description = bundled != null
        ? "$where, with $bundled bundled with the app"
        : tools?.proot != null
            ? "$where. There is no git and no package manager here; installing "
                "a Linux from the Terminal settings gives you both"
            : where;
    return ShellDriver(
      commandFor: (_, _, {readOnly = const []}) => [path],
      environment: {...?environment0, ...?tools?.environment},
      projectHome: projectHome,
      description: description,
      sandboxHelper: sandboxHelper,
    );
  }

  @override
  SandboxHelper? get driverSandboxHelper => _driver()?.sandboxHelper;

  /// Per chat, inside the sandbox's grant, so two chats' scratch never meet.
  @override
  String? tmpDirFor(String workspace) => "$workspace/.entoli-tmp";

  @override
  bool get platformIsWindows => Platform.isWindows;

  @override
  ValueListenable<String?>? sessionCwd(String cwd, {String? home}) {
    if (!canRunCommands) return null;
    // Seeding as the host path is deliberate: this shell's own report is the
    // machine's directory, and the session replaces it from its birth. A
    // guest driver's would mask here, but the driver is resolved per project
    // and this ask carries none — the guest's first marker corrects it.
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
      CommandSandbox? sandbox,
      List<String> readOnly = const []}) {
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
        command: driver?.commandFor(cwd, home, readOnly: readOnly) ?? const [],
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
        .start(command, timeout,
            environment: environment, restart: restart, readOnly: readOnly);
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
        defaults: defaultShellEnvironment,
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
  static String? resolveShell({
    String? path,
    bool Function(String)? isExecutable,
    bool? windows,
    Map<String, String>? environment,
  }) {
    final executable = isExecutable ?? _executable;
    final win = windows ?? Platform.isWindows;
    final env = environment ?? Platform.environment;
    final paths = win ? p.windows : p.posix;
    // WSL's `System32\bash.exe` runs a Linux that cannot take a Windows path.
    final systemRoot = (env["SystemRoot"] ?? r"C:\Windows").toLowerCase();
    final dirs = (path ?? env["PATH"] ?? "")
        .split(listSeparator(windows: win))
        .where((dir) => dir.isNotEmpty &&
            !(win &&
                (paths.equals(systemRoot, dir.toLowerCase()) ||
                    paths.isWithin(systemRoot, dir.toLowerCase()))))
        .toList();
    for (final name in win ? const ["bash.exe", "sh.exe"] : const ["bash", "sh"]) {
      for (final dir in dirs) {
        final candidate = paths.join(dir, name);
        if (executable(candidate)) return candidate;
      }
    }
    final fallbacks = win
        ? [
            for (final root in {env["ProgramFiles"], env["ProgramW6432"]})
              if (root != null) ...[
                paths.join(root, "Git", "bin", "bash.exe"),
                paths.join(root, "Git", "usr", "bin", "bash.exe"),
              ],
            // Git for Windows puts `cmd\git.exe` on PATH, its bash beside.
            for (final dir in dirs)
              if (executable(paths.join(dir, "git.exe")))
                paths.normalize(paths.join(dir, "..", "bin", "bash.exe")),
          ]
        : _fallbacks;
    for (final candidate in fallbacks) {
      if (executable(candidate)) return candidate;
    }
    return null;
  }

  static const _fallbacks = ["/bin/bash", "/system/bin/sh", "/bin/sh"];

  /// What separates the directories in a `PATH`.
  static String listSeparator({bool? windows}) =>
      (windows ?? Platform.isWindows) ? ";" : ":";

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
}

/// How a timeout is worded in an answer.
String _word(Duration d) =>
    d.inMilliseconds < 1000 ? "${d.inMilliseconds}ms" : "${d.inSeconds}s";

/// What the flush of a pipe whose writers have gone is worth waiting for. A
/// command that left one holding it pays this in full, once.
const _drainGrace = Duration(seconds: 2);

/// Signal a process's group where one was made, falling back to the process
/// itself. A group kill is preferred so a timed-out `npm install` that only
/// loses its shell does not keep downloading; the fallback is for a platform
/// whose `setsid` was not there to make a group at all.
///
/// Windows has neither groups nor signals: a kill there is `taskkill /T`, the
/// one way to take bash's children with it, and an interrupt is not sent.
void _signalGroup(Process process, bool ownsGroup, ProcessSignal signal) {
  if (Platform.isWindows) {
    if (signal == ProcessSignal.sigint) return;
    unawaited(Process.run(
            "taskkill", ["/T", "/F", "/PID", "${process.pid}"])
        .then<void>((r) {
      if (r.exitCode != 0) process.kill();
    }, onError: (Object e) {
      logFailure("shell", "taskkill failed", e);
      process.kill();
    }));
    return;
  }
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

/// The live tail after [piece] lands on [prior], bounded to [_liveWindow]. What a running command's block shows; both run shapes keep
/// one.
String _liveTail(String prior, String piece) {
  var out = prior + piece;
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
       {Map<String, String>? environment,
       bool restart = false,
       List<String> readOnly = const []}) {
    final run = _SessionRun(_RunState(timeout), this);
    _queue = _queue.then((_) => _execute(run, command, timeout,
        environment: environment, restart: restart, readOnly: readOnly));
    return run;
  }

  Future<void> _execute(
    _SessionRun run,
    String command,
    Duration timeout, {
    Map<String, String>? environment,
    bool restart = false,
    List<String> readOnly = const [],
  }) async {
    final driver = _shell._driver(project: _project);
    // A change in what is bound changes the fingerprint below, so the shell
    // respawns with it rather than standing in the old binds.
    final command0 =
        driver?.commandFor(_cwdPath, _home, readOnly: readOnly) ?? const [];
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
    _marker = dispatcherMarker(token);
    final argv = [...command.skip(1), "-c", dispatcherScript(token)];
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
    final line = buf.substring(start + 1, end);
    final rcAt = line.indexOf(" rc=") + " rc=".length;
    final cwdAt = line.indexOf(" cwd=", rcAt);
    if (cwdAt == -1) return;
    final rc = int.tryParse(line.substring(rcAt, cwdAt));
    if (rc == null) return;
    // Only once the whole sentinel parsed, so a partial one loses nothing.
    run.chunks.clear();
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
              ? "The command timed out after ${_word(run.timeout)} and was "
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
    // No Ctrl-C to send on Windows, so the stop is the kill.
    if (Platform.isWindows) {
      _killGroup();
      return;
    }
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

  String get output => chunks.join("");

  /// What the live view of this run says now: the tail of the output, with
  /// any fragment at its end that could be the sentinel's head held back
  /// until the next chunk settles what it was — newline included, so output
  /// that only looked like the sentinel keeps its line break.
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
      _held = joined.substring(cut);
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

class _SessionRun extends ShellRun {
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
/// as a failed command; `_run` catches it as its own case so the fail-closed
/// reason reaches the model un-mangled.
class ShellUnavailable implements Exception {
  const ShellUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What a `oneShot` command is: today's contract, a fresh subshell per
/// command, kept for sub-agents and for the platforms a persistent shell
/// would only complicate.
class _OneShotRun extends ShellRun {
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
  Future<int?> get pid => _pid.future;
  final _pid = Completer<int?>();

  @override
  Future<void> kill() async {
    _killed = true;
    _killTree();
  }

  Future<ShellResult> _run() async {
    if (command.isEmpty) {
      _pid.complete(null);
      return const ShellResult.failed(
          "No shell was found on this device to execute commands in.");
    }
    final output = StringBuffer();
    Timer? timer;
    try {
      _process = await _spawn();
      final process = _process!;
      _pid.complete(process.pid);
      // Merged in the shell rather than here: two Dart streams arrive in
      // whatever order the pipes flush, and a compiler's errors interleaved
      // with its progress is the whole value of reading them.
      final reading = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((chunk) {
        output.write(chunk);
        _publish(chunk);
      });
      // The confinement's own stderr, before any shell runs to merge its own:
      // a ruleset that failed to come up prints why, and that reason is the
      // model's only lead. Lost, it was an rc=91 with nothing beside it.
      process.stderr
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
      final text = output.toString();
      if (!_killed && timer.isActive) {
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
    } on ShellUnavailable catch (e) {
      // Fail-closed has its own words: a confinement that did not happen is
      // not a spawn error, and the reason is what the model rewrites around.
      // The log line is how a machine that keeps failing here is found —
      // this is the arm a user's report lands in with nothing beside it.
      logFailure("sandbox", "a confined command was not run", e.message);
      return ShellResult.failed(e.message, output: output.toString());
    } catch (e) {
      return ShellResult.failed(
        "An error occurred while executing the command: $e",
        output: output.toString(),
      );
    } finally {
      timer?.cancel();
      if (!_pid.isCompleted) _pid.complete(null);
    }
  }

  /// `exec 2>&1` redirects the shell's own error output and everything it goes
  /// on to spawn, which is what makes the transcript read in order. Its input
  /// is nothing, as a session command's is: a pipe nobody writes to never
  /// ends, so a command that reads it waits for the timeout.
  ///
  /// Whether `setsid` exists is learned by trying it rather than by probing
  /// first: a failed spawn says the same thing without costing a subprocess.
  Future<Process> _spawn() async {
    final body = "exec 2>&1 </dev/null\n$script";
    var argv = [...command.skip(1), "-c", body];
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
      argv = [...prefix.skip(1), ...command, "-c", body];
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
