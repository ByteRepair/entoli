import "dart:async";
import "dart:convert";
import "dart:io";

import "../../domain/shell.dart";

/// Runs commands on the machine the app is on. Every command is a fresh
/// subshell — the contract inherited from mini-swe-agent — so `cd` and exports
/// do not carry over, which is why the agent is told to prefix them instead.
class LocalShell extends Shell {
  LocalShell({Map<String, String> Function()? environment})
      : _environment = environment ?? _none;

  /// Applied over the process's own environment. Read at each command rather
  /// than captured, so a variable added in settings reaches the next one.
  final Map<String, String> Function() _environment;

  static Map<String, String> _none() => const {};

  /// Set once we know whether `setsid` is on this machine. Without it a
  /// timeout can only kill the shell, leaving whatever it spawned running.
  static bool? _hasSetsid;

  @override
  String get platformDescription =>
      "${Platform.operatingSystem} ${Platform.operatingSystemVersion}";

  @override
  ShellRun start(String command, {required String cwd, required Duration timeout}) =>
      _LocalRun(
        command: command,
        cwd: cwd,
        timeout: timeout,
        environment: {..._defaults, ..._environment()},
      );

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
    required this.cwd,
    required this.timeout,
    required this.environment,
  }) {
    result = _run();
  }

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
    final script = "exec 2>&1\n$command";
    if (LocalShell._hasSetsid != false) {
      try {
        final process = await Process.start(
          "setsid",
          [_shell, "-c", script],
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
      _shell,
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

  static final _shell = File("/bin/bash").existsSync() ? "/bin/bash" : "/bin/sh";
}
