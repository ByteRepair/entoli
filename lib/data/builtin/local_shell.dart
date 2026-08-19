import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";

import "../../domain/shell.dart";

/// Runs commands on the machine the app is on. Every command is a fresh
/// subshell — the contract inherited from mini-swe-agent — so `cd` and exports
/// do not carry over, which is why the agent is told to prefix them instead.
class LocalShell extends Shell {
  LocalShell({Map<String, String> Function()? environment, String? Function()? shell})
      : _environment = environment ?? _none,
        _shell = shell ?? _machineShell;

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
  String get platformDescription =>
      "${Platform.operatingSystem} ${Platform.operatingSystemVersion}, "
      "commands run under ${_shell() ?? "no shell"}";

  /// False where the machine has no shell to offer. Android is why this is not
  /// a constant: it has no `/bin` at all, and a device whose `PATH` turns up
  /// nothing is one where every command would otherwise fail one at a time.
  @override
  bool get canRunCommands => _shell() != null;

  @override
  ShellRun start(String command, {required String cwd, required Duration timeout}) =>
      _LocalRun(
        shell: _shell(),
        command: command,
        cwd: cwd,
        timeout: timeout,
        environment: {..._defaults, ..._environment()},
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
    required this.shell,
    required this.command,
    required this.cwd,
    required this.timeout,
    required this.environment,
  }) {
    result = _run();
  }

  final String? shell;
  final String command;
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
    final shell = this.shell;
    if (shell == null) {
      return const ShellResult.failed(
          "No shell was found on this device to execute commands in.");
    }
    final output = StringBuffer();
    Timer? timer;
    try {
      _process = await _spawn(shell);
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
  Future<Process> _spawn(String shell) async {
    final script = "exec 2>&1\n$command";
    if (LocalShell._hasSetsid != false) {
      try {
        final process = await Process.start(
          "setsid",
          [shell, "-c", script],
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
      shell,
      ["-c", script],
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
