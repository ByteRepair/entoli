import "package:entoli_core/model/shell.dart" show SandboxHelper, Shell;

/// What this build ships beside the machine's own commands: the environment a
/// command needs to find them, and the name the model is told they are there
/// under. One value rather than two, so nothing can lay them out and forget to
/// say so — see "Bundled tools" in `AGENTS.md`.
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
/// whole point of them — see "A whole Linux under proot" in `AGENTS.md`.
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
/// `platformDriver` picks one per command.
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
  /// workspace at a clean path and sets `-w` to the guest path, and binds
  /// each of `readOnly` at its own host path, its root kept from writing
  /// there; a host driver returns the same list regardless.
  final List<String> Function(String cwd, String home, {List<String> readOnly})
  commandFor;

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
  /// per-app sandbox already bounds it) — and non-null on the desktops, where
  /// a command's text and its behaviour can disagree and the kernel is what
  /// settles it.
  final SandboxHelper? sandboxHelper;
}
