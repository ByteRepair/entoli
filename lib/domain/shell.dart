/// Where the agent's commands run. Desktop and Android have a real shell; a
/// browser does not, and that is the whole of the difference between the
/// platforms' agent. The `!` syntax that sends a message to the shell instead
/// of the model is here too, since it is the same shell it reaches.
library;

import "package:flutter/foundation.dart" show ValueListenable;

/// The command a message runs itself, or null where it is prose for the model.
/// A leading `!` is the whole of the rule, and what follows it is the command —
/// blank included, so the composer can say what it is about to do from the
/// keystroke that decides it rather than a word later.
///
/// Read in four places: the backend dispatches on it, the projection words the
/// run for the model, and the composer and the bubble draw a command rather
/// than something said. See "Running a command yourself".
String? shellBypassCommand(String text) =>
    text.startsWith("!") ? text.substring(1).trim() : null;

/// What a command produced. Mirrors mini-swe-agent's observation shape: a
/// return code of -1 means the command never ran to completion, and
/// [exceptionInfo] says why.
class ShellResult {
  const ShellResult({
    required this.returnCode,
    required this.output,
    this.exceptionInfo,
    this.cwd,
  });

  const ShellResult.failed(this.exceptionInfo,
      {this.output = ""}) :
    returnCode = -1,
    cwd = null;

  final int returnCode;
  final String output;
  final String? exceptionInfo;

  /// The working directory the shell was left in, from a shell whose state
  /// carries over — the one that runs the chat's commands. Null where there is
  /// no such state to report: a one-shot subshell is gone with the command,
  /// and a command that was killed or never ran left no directory to read.
  final String? cwd;
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

/// What a command runs under: the executable that ends in the shell, the
/// environment that shell starts with, whose home its `HOME` is, and the
/// sentence the model is told. One value again, and the same reason: what a
/// command is run under and what the model is told it is on cannot be allowed
/// to disagree.
///
/// The machine's own shell is a driver too, which is what lets a guest, an
/// emulator or a container arrive as a new value the shell does not have to
/// learn about: the session machinery runs whatever [commandFor] ends in, and
/// the resolver in `core/platform/` picks one per command.
class ShellDriver {
  const ShellDriver({
    required this.commandFor,
    required this.environment,
    required this.projectHome,
    required this.description,
    this.guestRoot,
    this.hostToGuestPaths = const {},
    this.includeParentEnvironment = true,
  });

  /// The executable and its arguments, ending in the shell a command runs in,
  /// built for the chat's own [cwd] and [home]. A guest driver binds the
  /// workspace at a clean path and sets `-w` to the guest path; a host driver
  /// returns the same list regardless.
  final List<String> Function(String cwd, String home) commandFor;

  /// The environment the shell starts with, below the app's and the project's
  /// variables, which still win over it. A guest's, where [commandFor] reaches
  /// a guest: the host toolset's paths are the host's, and a command inside the
  /// guest should find none of them.
  final Map<String, String> environment;

  /// Whether a command's `HOME` is the project workspace rather than the
  /// machine's own home directory. True of a driver that reaches a guest,
  /// whose home is one directory every project would share; on the machine
  /// itself [Shell.start]'s `sharedHome` answers for it instead.
  final bool projectHome;

  /// Where the project workspace appears inside the guest (`/root` for proot),
  /// or null on the machine itself. The file tools translate paths under it
  /// back to the host's, and the system prompt uses `~` in its place.
  final String? guestRoot;

  /// Host path prefixes mapped to their guest equivalents, for translating
  /// paths the model is told (skill base directories) into the guest's
  /// vocabulary. Empty on the machine itself.
  final Map<String, String> hostToGuestPaths;

  /// What the model is told it is operating on, e.g. `Alpine Linux 3.24
  /// (aarch64)`, or the machine's own shell where the command runs on the
  /// machine itself. The agent's system prompt carries it.
  final String description;

  /// Whether the process's own environment is merged under [environment]. A
  /// host driver inherits the machine's `PATH`, `DISPLAY` and the rest; a guest
  /// driver does not, since the parent's values are host paths the guest cannot
  /// see and [environment] names every var the guest needs.
  final bool includeParentEnvironment;
}

/// A command already running. Separate from its result so an aborted turn can
/// [kill] a build that would otherwise carry on for minutes.
abstract class ShellRun {
  /// Completes when the command does or when it is killed, whichever comes
  /// first. The agent awaits it with no bound of its own, so an implementation
  /// that waits on a handle it cannot close is a turn that can never end.
  Future<ShellResult> get result;

  /// What the command has printed so far, as it prints it. Only the tail is
  /// promised — the live view of a command whose output is measured in
  /// megabytes is the last of it, not the whole — and it stops changing once
  /// [result] completes. Null where nothing has printed yet.
  ///
  /// The sentinel that ends a run never appears here: whatever is held back is
  /// only the remainder of a possible one, and [result]'s [ShellResult.output]
  /// is still the whole of what the command printed.
  ValueListenable<String?>? get output => null;

  Future<void> kill();
}

abstract class Shell {
  const Shell();

  /// [cwd] is where the command starts, [home] the `HOME` it is given — the
  /// chat's directory and the project workspace above it. A sandbox always
  /// takes [home] for its guest, and so does a turn whose home it does not
  /// share ([sharedHome] false): a home nothing shares is the chat's own.
  /// Where the home is shared on a machine, `HOME` is the user's and stays
  /// that way. [environment] is layered over whatever the app's settings
  /// provide, with a name set in it winning over the app-level one — the
  /// project's own variables, which the app-level are the fallback for.
  ///
  /// [oneShot] runs the command in a subshell that is gone when it finishes:
  /// no `cd` or export carries over to anything after it. That is what
  /// sub-agents run under — a fan-out of workers that need concurrency, not a
  /// terminal. The default is the chat's own persistent shell, one per [cwd],
  /// whose state carries over from one command to the next and which the
  /// agent's commands and the user's `!` commands share.
  ///
  /// [restart] drops that shell's state before running: the command starts
  /// back in [cwd] with nothing exported.
  ShellRun start(String command,
      {required String cwd,
      required String home,
      required Duration timeout,
      Map<String, String>? environment,
      bool sharedHome = true,
      bool oneShot = false,
      bool restart = false,
      String? project});

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

  /// Whether a command's `HOME` is the project workspace rather than the
  /// machine's own because the shell reaches a guest, whose home is one
  /// directory every project would share. A shell on the machine itself is
  /// false, where [start]'s `sharedHome` answers for it instead.
  bool get projectHome => false;

  /// Where the project workspace appears inside the guest (`/root` for proot),
  /// or null on the machine itself. The file tools translate paths under it
  /// back to the host's, and the system prompt uses `~` in its place.
  String? get guestRoot => null;

  /// Host path prefixes mapped to their guest equivalents, for translating
  /// paths the model is told into the guest's vocabulary. Empty on the machine.
  Map<String, String> get hostToGuestPaths => const {};

  /// Where [cwd]'s persistent shell is standing, live: the directory a `cd`
  /// in it leaves it in. Null where this shell runs nothing persistent or has
  /// no session for [cwd] yet, which the caller falls back to [cwd] itself
  /// for. The composer's bar is what asks.
  ValueListenable<String?>? sessionCwd(String cwd) => null;

  /// End [cwd]'s persistent shell, where this one runs them. A no-op where it
  /// does not. Called when the chat the shell belongs to is deleted or leaves
  /// its project: a shell standing in a directory that is gone — or moving —
  /// is a process outliving the thing it was for.
  void closeSession(String cwd) {}
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
  ShellRun start(String command,
          {required String cwd,
          required String home,
          required Duration timeout,
          Map<String, String>? environment,
          bool sharedHome = true,
          bool oneShot = false,
          bool restart = false,
          String? project}) =>
      const _Unavailable();
}

class _Unavailable implements ShellRun {
  const _Unavailable();

  @override
  Future<ShellResult> get result async =>
      const ShellResult.failed("There is no shell here to execute commands in.");

  @override
  ValueListenable<String?>? get output => null;

  @override
  Future<void> kill() async {}
}
