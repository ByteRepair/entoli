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

/// What this build ships beside the machine's own commands: the environment a
/// command needs to find them, and the name the model is told they are there
/// under. One value rather than two, so nothing can lay them out and forget to
/// say so — see "Bundled tools" in CLAUDE.md.
class Toolset {
  const Toolset({required this.environment, this.names, this.proot});

  final Map<String, String> environment;

  /// Null where this build ships no commands of its own, which is a build that
  /// ships only [proot] — nothing the model runs by name.
  final String? names;

  /// What can run a whole Linux, where this build ships one. Here rather than
  /// beside the toolset for the reason the toolset is one value: both are
  /// executables laid out by the same install, and a second return value is one
  /// a caller can take and forget.
  final Proot? proot;
}

/// Everything needed to run a command inside a downloaded Linux, bar the Linux.
/// [binary] and [loader] are in the native library directory, which is the
/// whole point of them — see "A whole Linux under proot" in CLAUDE.md.
class Proot {
  const Proot({
    required this.binary,
    required this.loader,
    required this.tmpDir,
    required this.resolvConf,
    this.loader32,
  });

  final String binary;
  final String loader;

  /// For a guest binary of the other word size, where the architecture has one.
  final String? loader32;

  /// Writable, and both proot's own scratch space and the guest's `/tmp`.
  final String tmpDir;

  /// The host file bound over the guest's `/etc/resolv.conf`. Written at every
  /// launch from what Android says the network resolves with, since a guest has
  /// no other way to ask.
  final String resolvConf;
}

/// A guest system the agent's commands run *inside* rather than beside. One
/// value again, and the same reason: what a command is run under and what the
/// model is told it is on cannot be allowed to disagree.
class Sandbox {
  const Sandbox({
    required this.command,
    required this.environment,
    required this.description,
  });

  /// The executable and its arguments, ending in the guest's own shell. The
  /// script goes on the end as `-c`, exactly as it does without one.
  final List<String> command;

  /// The guest's environment. It **replaces** [Toolset.environment] rather than
  /// layering over it: the bundled git is a bionic binary and its `GIT_EXEC_PATH`
  /// names a host directory, neither of which is what a command inside the guest
  /// should find. Settings still win over both.
  final Map<String, String> environment;

  /// What the model is told it is on, e.g. `Alpine Linux 3.24 (aarch64)`.
  final String description;
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
