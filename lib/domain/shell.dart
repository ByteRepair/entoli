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
    this.violations = const [],
  });

  const ShellResult.failed(this.exceptionInfo, {this.output = ""})
      : returnCode = -1,
        cwd = null,
        violations = const [];

  final int returnCode;
  final String output;
  final String? exceptionInfo;

  /// The working directory the shell was left in, from a shell whose state
  /// carries over — the one that runs the chat's commands. Null where there is
  /// no such state to report: a one-shot subshell is gone with the command,
  /// and a command that was killed or never ran left no directory to read.
  final String? cwd;

  /// What the sandbox denied while the command ran, appended to the tool
  /// result the model reads, so it rewrites instead of retrying blind. Empty
  /// where nothing was denied or where the command ran with no sandbox.
  final List<String> violations;
}

/// What this build ships beside the machine's own commands: the environment a
/// command needs to find them, and the name the model is told they are there
/// under. One value rather than two, so nothing can lay them out and forget to
/// say so — see "Bundled tools" in AGENTS.md.
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

/// The confinement one command runs under, described where it will be
/// applied. [CommandSandbox.workspace] is the directory the conversation may
/// write to freely — the chat's own workspace on the host — and [tmp] the
/// scratch the OS gives the command; writes anywhere else are what the kernel
/// refuses. The profile files in `$HOME` — `.bashrc`, `.gitconfig`, `.ssh` —
/// are *inside* [home] where the desktop's real home is reachable, which is
/// why the sandbox's write side is an allowlist rather than a denylist: read
/// everything, write the workspace and tmp, and those files fall outside the
/// granted set without being named.
class CommandSandbox {
  const CommandSandbox({
    required this.workspace,
    this.tmp,
    this.home,
    this.extraWrites = const [],
  });

  /// The one directory writes are granted, at its host path.
  final String workspace;

  /// The scratch directory writes are allowed in; a command's own TMPDIR
  /// where one is laid out for it.
  final String? tmp;

  /// The `HOME` the command sees, where that differs from the workspace — a
  /// desktop command's own home, which is read freely and written never.
  final String? home;

  /// Directories beyond [workspace] and [tmp] the command may write to — the
  /// machine paths a permission rule or a project names as part of its work.
  /// Granted the full write set the workspace gets.
  final List<String> extraWrites;

  /// The sentence the tool result carries when this sandbox denied something.
  static String violationsNote(List<String> violations) =>
      "\n\nDenied by the sandbox: ${violations.join("; ")}. The command "
      "carried on; what it printed above is what it could reach.";
}

/// Whether [path] is [root] or under it, compared by components so `/w/x`
/// does not match `/wextra`.
bool pathInside(String path, String root) {
  if (root == "/" || root.isEmpty) return true;
  final p = _trimSlash(path);
  final r = _trimSlash(root);
  return p == r || p.startsWith("$r/");
}

String _trimSlash(String path) =>
    path.length > 1 && path.endsWith("/") ? path.substring(0, path.length - 1) : path;

/// What turns a command into one that enforces [sandbox] on itself, by the
/// helper the OS driver owns. Null where this build has no confinement for
/// the platform — which is the only case where a confinement-requiring
/// command fails closed.
abstract class SandboxHelper {
  /// The argv that runs everything after it confined: the helper's own
  /// invocation, ending where the confined command's argv continues. Null
  /// where the helper cannot be built — the binary is missing, the kernel is
  /// too old — which the caller reports rather than working around.
  ///
  /// A prefix rather than a whole command, because the two run shapes need
  /// different tails: a one-shot subshell appends its shell with the script,
  /// and the chat's persistent shell appends its shell with the dispatcher —
  /// the session's `cd` and exports live *inside* the confined shell, which
  /// is the shape that keeps the state a session exists to keep.
  Future<List<String>?> prefixFor(CommandSandbox sandbox);

  /// The file the confinement's denials are reported to, one line per
  /// refused syscall, or null where this helper has no report channel. The
  /// caller reads it after the run and words what it holds; it lives under
  /// the grant so the confined command could write it. Null is honest —
  /// the prose cross-check takes over — never a wrong report.
  String? reportPathFor(CommandSandbox sandbox) => null;

  /// The shim library that writes the report, exported to the confined
  /// command beside [reportPathFor]'s file. Null together with it.
  String? get reportShimPath => null;
}

/// Everything needed to run a command inside a downloaded Linux, bar the Linux.
/// [binary] and [loader] are in the native library directory, which is the
/// whole point of them — see "A whole Linux under proot" in AGENTS.md.
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
    this.sandboxHelper,
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

  /// Whether a command's `HOME` is the workspace passed to [Shell.start]
  /// rather than the machine's own home directory. True of a driver that
  /// reaches a guest, whose home is one directory every project would share,
  /// and of a host with no user home of its own to give (Android). False on
  /// the desktops, where the machine user's own `HOME` stands and nothing
  /// overrides it.
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

  /// The confinement a command can be run under, where this driver's OS
  /// offers one the process can reach. Null everywhere the answer is "no
  /// sandbox here" — a guest (its rootfs is the boundary), Android (the
  /// per-app sandbox already bounds it), the web (no shell at all) — and
  /// non-null on the desktops, where a command's text and its behaviour can
  /// disagree and the kernel is what settles it.
  final SandboxHelper? sandboxHelper;
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
  /// [result] completes. Null where nothing has printed yet, and null while
  /// nobody is watching: **asking is the watch**. A shell is free to keep
  /// nothing at all per chunk until this is first read, which is what keeps
  /// an unwatched run — a sub-agent's — from paying for a view nobody sees.
  ///
  /// The sentinel that ends a run never appears here: whatever is held back is
  /// only the remainder of a possible one, and [result]'s [ShellResult.output]
  /// is still the whole of what the command printed.
  ValueListenable<String?>? get output => null;

  Future<void> kill();
}

abstract class Shell {
  const Shell();

  /// [cwd] is where the command starts, [home] the `HOME` it is given where
  /// its driver takes one — the chat's directory or the project workspace
  /// above it; where the driver runs on the machine itself the machine user's
  /// own home stands and nothing is set. [environment] is layered over
  /// whatever the app's settings provide, with a name set in it winning over
  /// the app-level one — the project's own variables, which the app-level are
  /// the fallback for.
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
  ///
  /// [sandbox] is the confinement this one command runs under, where the
  /// driver offers one and the caller wants it — null runs the command as the
  /// shell itself runs, which is what a session shell does with its state,
  /// and what a platform with no confinement to offer is handed.
  ShellRun start(String command,
      {required String cwd,
      required String home,
      required Duration timeout,
      Map<String, String>? environment,
      bool oneShot = false,
      bool restart = false,
      String? project,
      CommandSandbox? sandbox});

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

  /// Whether a command's `HOME` is the workspace rather than the machine's
  /// own, because the driver that runs it takes one — a guest's home is one
  /// directory every project would share, and a host with no real user home
  /// (Android) takes the workspace. A shell on the desktops is false: the
  /// machine user's own home stands. See [Shell.machineHome].
  bool get projectHome => false;

  /// The machine user's own home directory; null where there is no machine
  /// behind the shell or no real user home to name.
  String? get machineHome => null;

  /// The `HOME` a command in this chat is given — and, being that, what `~`
  /// means to it. One answer, so the prompt and the file tools read the same
  /// place [composeEnvironment] sets. Null where there is nothing to name.
  String? homeFor(String home) => machineHome;

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

  /// The confinement a command can be run under, from the driver that would
  /// run it, or null where this shell's platforms offer none — a guest (its
  /// rootfs is the boundary), Android (the per-app sandbox is the OS's), the
  /// web (no shell at all).
  SandboxHelper? get driverSandboxHelper => null;

  /// The scratch directory a sandboxed command may write beside [workspace],
  /// or null where this shell lays none out. The workspace itself is granted
  /// by every sandbox; this is the second path a command's temp files land
  /// in, and it is named by the shell because the shell knows where its
  /// platform's tmp is.
  String? tmpDirFor(String workspace) => null;

  /// Whether this shell's commands are modeled as POSIX shell. False only on
  /// Windows, whose `cmd` is not; a parse there would be a guess, and a guess
  /// in the deterministic layer is the thing this layer does not make.
  bool get platformIsWindows => false;
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
          bool oneShot = false,
          bool restart = false,
          String? project,
          CommandSandbox? sandbox}) =>
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

/// What mini-swe-agent's own config sets: anything that would otherwise wait
/// for a keypress or redraw a progress bar into the transcript. `BASH_ENV`
/// is the empty one because a non-interactive shell sources it, and this
/// shell answers to nothing but its queue.
const defaultShellEnvironment = {
  "PAGER": "cat",
  "MANPAGER": "cat",
  "GIT_PAGER": "cat",
  "LESS": "-R",
  "PIP_PROGRESS_BAR": "off",
  "TQDM_DISABLE": "1",
  "TERM": "dumb",
  "BASH_ENV": "",
};

/// The persistent-shell dispatcher script, templated on a per-session token.
/// Both the host shell ([LocalShell]) and the in-process emulator
/// ([IshShell]) use it, which is why it lives here: the contract — a Ctrl-C
/// the shell traps into a 130 while keeping its state, an `EXIT` trap that
/// reports where the shell died, and a base64 line that keeps a multi-line
/// command from stealing the queue — is the same whether the shell is a child
/// process or an emulated guest. The marker carries the token so a command's
/// output cannot forge the end of a run.
///
/// `IshShell`'s guest runs this inside iSH's `/bin/sh`, so a `cd` or an
/// `export` in one emulated command sticks for the next, the same way it does
/// on a real child process.
String dispatcherScript(String token) => _dispatcherTemplate.replaceAll(
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

/// The marker a completed command writes, parsed back for the result. Built
/// from the same token [dispatcherScript] uses, so what scans the output is
/// what wrote it.
String dispatcherMarker(String token) => "@@E$token rc=";
