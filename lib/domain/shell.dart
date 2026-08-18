/// Where the agent's commands run. Desktop and Android have a real shell; a
/// browser does not, and that is the whole of the difference between the
/// platforms' agent.
library;

/// What a command produced. Mirrors mini-swe-agent's observation shape: a
/// return code of -1 means the command never ran to completion, and
/// [exceptionInfo] says why.
class ShellResult {
  const ShellResult({
    required this.returnCode,
    required this.output,
    this.exceptionInfo,
  });

  const ShellResult.failed(this.exceptionInfo, {this.output = ""}) : returnCode = -1;

  final int returnCode;
  final String output;
  final String? exceptionInfo;
}

/// A command already running. Separate from its result so an aborted turn can
/// [kill] a build that would otherwise carry on for minutes.
abstract class ShellRun {
  /// Completes when the command does or when it is killed, whichever comes
  /// first. The agent awaits it with no bound of its own, so an implementation
  /// that waits on a handle it cannot close is a turn that can never end.
  Future<ShellResult> get result;

  Future<void> kill();
}

abstract class Shell {
  const Shell();

  ShellRun start(String command, {required String cwd, required Duration timeout});

  /// What the model is told it is operating on, e.g. `Linux 6.11.0 x86_64`.
  /// The agent's system prompt names it, so a command can be written for the
  /// right platform.
  String get platformDescription;

  /// Whether there is anything to run at all. False turns the whole loop into
  /// a plain conversation: the agent stops offering the tool, and a reply with
  /// no command in it becomes the end of the turn rather than a format error.
  /// Without that, a browser could never finish a turn — submitting is itself
  /// a command.
  bool get canRunCommands => true;
}

/// The web's shell: there isn't one. A command that reaches it anyway is
/// reported as failed rather than thrown, so the model is told why instead of
/// the turn dying.
class UnavailableShell extends Shell {
  const UnavailableShell();

  @override
  String get platformDescription => "a browser, with no shell to run commands in";

  @override
  bool get canRunCommands => false;

  @override
  ShellRun start(String command, {required String cwd, required Duration timeout}) =>
      const _Unavailable();
}

class _Unavailable implements ShellRun {
  const _Unavailable();

  @override
  Future<ShellResult> get result async =>
      const ShellResult.failed("There is no shell here to execute commands in.");

  @override
  Future<void> kill() async {}
}
