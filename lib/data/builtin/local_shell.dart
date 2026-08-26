import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";

import "../../domain/shell.dart";

/// Runs commands on the machine the app is on. Every command is a fresh
/// subshell — the contract inherited from mini-swe-agent — so `cd` and exports
/// do not carry over, which is why the agent is told to prefix them instead.
class LocalShell extends Shell {
  LocalShell({
    Map<String, String> Function()? environment,
    String? Function()? shell,
    Sandbox? Function()? sandbox,
    this.tools,
  })  : _environment = environment ?? _none,
        _shell = shell ?? _machineShell,
        _sandbox = sandbox ?? _nothing;

  /// What this build ships beside the machine's own commands. Null where
  /// nothing is bundled, which is every platform but Android — see "Bundled
  /// tools" in CLAUDE.md.
  final Toolset? tools;

  /// The Linux commands are run inside, where the user has installed one. Read
  /// at each command for the reason [_environment] is: installing one from the
  /// settings page, or going back to Android, reaches the next command rather
  /// than the next launch.
  final Sandbox? Function() _sandbox;

  static Sandbox? _nothing() => null;

  /// What lets a test say there is no shell here without the machine agreeing.
  /// Not for the reason [_environment] is a callback: that one is re-read so a
  /// variable added in settings reaches the next command, where this answers
  /// [shellPath], resolved once for the life of the process.
  final String? Function() _shell;

  static String? _machineShell() => shellPath;

  /// Applied over the process's own environment. Read at each command rather
  /// than captured, so a variable added in settings reaches the next one.
  final Map<String, String> Function() _environment;

  static Map<String, String> _none() => const {};

  /// Set once we know whether `setsid` is on this machine. Without it a
  /// timeout can only kill the shell, leaving whatever it spawned running.
  static bool? _hasSetsid;

  @override
  String get platformDescription {
    final sandbox = _sandbox();
    if (sandbox != null) {
      return "${sandbox.description}. It is running under proot on "
          "${Platform.operatingSystem} ${Platform.operatingSystemVersion}, so "
          "filesystem-heavy commands are slower than they look";
    }
    final where = "${Platform.operatingSystem} ${Platform.operatingSystemVersion}, "
        "commands run under ${_shell() ?? "no shell"}";
    final bundled = tools?.names;
    if (bundled != null) return "$where, with $bundled bundled with the app";
    // Android's shell is toybox and nothing else — no git, and no way to add
    // one outside a guest. Said rather than left to be discovered, since the
    // alternative is the model working around the absence one `command not
    // found` at a time.
    if (Platform.isAndroid && tools?.proot != null) {
      return "$where. There is no git and no package manager here; installing "
          "a Linux from the Terminal settings gives you both";
    }
    return where;
  }

  /// False where the machine has no shell to offer. Android is why this is not
  /// a constant: it has no `/bin` at all, and a device whose `PATH` turns up
  /// nothing is one where every command would otherwise fail one at a time. A
  /// sandbox brings its own shell, so it answers for itself.
  @override
  bool get canRunCommands => _sandbox() != null || _shell() != null;

  @override
  ShellRun start(String command,
      {required String cwd,
      required String home,
      required Duration timeout,
      bool sharedHome = true}) {
    final sandbox = _sandbox();
    final shell = _shell();
    return _LocalRun(
      // The guest's shell, and everything proot needs to reach it, or the
      // machine's own where there is no guest. Empty is a machine with neither,
      // which is what the browser's shell already reports.
      command: sandbox?.command ?? [?shell],
      script: command,
      cwd: cwd,
      timeout: timeout,
      // Settings last, so a variable the user set wins over both what the
      // shell wants and what is bundled — PATH being the one they are likely to
      // disagree about. The sandbox's environment stands in place of the
      // toolset's rather than beside it: inside the guest, a host `PATH` names
      // directories that are not there.
      environment: {
        ..._defaults,
        ...?sandbox == null ? tools?.environment : sandbox.environment,
        // The guest's `/root` is one directory every project would share,
        // and a home that is not shared is the chat's own: both take
        // [home]. Where the home is shared, the machine's own `HOME` stands.
        if (sandbox != null || !sharedHome) "HOME": home,
        ..._environment(),
      },
    );
  }

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
  /// for a keypress or redraw a progress bar into the transcript.
  static const _defaults = {
    "PAGER": "cat",
    "MANPAGER": "cat",
    "GIT_PAGER": "cat",
    "LESS": "-R",
    "PIP_PROGRESS_BAR": "off",
    "TQDM_DISABLE": "1",
    "TERM": "dumb",
  };
}

class _LocalRun implements ShellRun {
  _LocalRun({
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
    if (LocalShell._hasSetsid != false) {
      try {
        final process = await Process.start(
          "setsid",
          [command.first, ...argv],
          workingDirectory: cwd,
          environment: environment,
        );
        // setsid execs in place, so the pid it reports is the new group's.
        LocalShell._hasSetsid = true;
        _ownsGroup = true;
        return process;
      } on ProcessException {
        LocalShell._hasSetsid = false;
      }
    }
    return Process.start(
      command.first,
      argv,
      workingDirectory: cwd,
      environment: environment,
    );
  }

  /// Kill the whole process group where we made one: a timed-out `npm install`
  /// that only loses its shell keeps downloading.
  void _killTree() {
    final process = _process;
    if (process == null) return;
    if (_ownsGroup) {
      try {
        if (Process.killPid(-process.pid, ProcessSignal.sigkill)) return;
      } catch (_) {}
    }
    process.kill(ProcessSignal.sigkill);
  }

  /// What the flush of a pipe whose writers have gone is worth waiting for. A
  /// command that left one holding it pays this in full, once.
  static const _drainGrace = Duration(seconds: 2);
}
