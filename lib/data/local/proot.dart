import "dart:ffi" show Abi;
import "dart:io" show Platform;

import "../../domain/file_tools.dart";
import "../../domain/rootfs.dart";
import "../../domain/rootfs_store.dart";
import "../builtin/llm/llm_client.dart" show LlmException;
import "../builtin/llm/providers/cli.dart"
    show CliProcess, LinuxCliGuest, launchProcess;
import "../../domain/shell.dart";

/// How a command is run inside a downloaded Linux: the proot invocation, the
/// environment on both sides of it bar `HOME`, and the sentence the model is
/// told.
///
/// A pure function over paths, deliberately — what proot is asked to do is the
/// part of this feature that can be pinned by a test on a machine with no
/// Android on it.
ShellDriver prootDriver({
  required Proot proot,
  required Rootfs rootfs,
  required String rootfsDir,
  required String defaultSkillsBundledDir,
  required String defaultUserSkillsDir,
  String? projectSkillsBundledDir,
  String? projectUserSkillsDir,
  String? abi,
}) {
  // Default's skills are the base set; a project's override same-named ones for
  // that project alone. Both are bound into the guest at distinct paths so the
  // model can reach an inherited skill and a project's override of another at
  // the same time. The project's dirs are absent where the project is the
  // default one or has no skills of its own.
  final binds = <String>[];
  final hostToGuest = <String, String>{};
  void bind(String host, String guest) {
    binds.add("-b");
    binds.add("$host:$guest");
    hostToGuest[host] = guest;
  }

  bind(defaultSkillsBundledDir, "/opt/skills-bundled");
  bind(defaultUserSkillsDir, "/opt/skills");
  if (projectSkillsBundledDir != null) {
    bind(projectSkillsBundledDir, "/opt/skills-bundled-project");
  }
  if (projectUserSkillsDir != null) {
    bind(projectUserSkillsDir, "/opt/skills-project");
  }

  return ShellDriver(
    commandFor: (cwd, home, {readOnly = const []}) => _prootCommand(
      proot,
      rootfsDir,
      readOnly: readOnly,
      binds: [
        // The project workspace at a clean guest path, not its own Android
        // path. The chat's workspace is inside it, so it is reachable at
        // $guestHome + the suffix of cwd past home. The rest of the device
        // is not there.
        "-b", "$home:$guestHome",
        // Skills need a real base directory so their scripts run; bound at
        // clean paths so the model is told those, not the host's. A
        // project's own skills dirs are bound beside the default's, so an
        // inherited skill and a project override are both reachable.
        ...binds,
        // At their own host paths, so the path the model is told of an
        // attachment is one answer whichever shell it runs in. A skills
        // directory is bound at its clean path above already.
        for (final dir in readOnly)
          if (!hostToGuest.containsKey(dir)) ...["-b", "$dir:$dir"],
      ],
      // The guest path of the chat workspace, not "." — proot stores -w as
      // the guest cwd, and "." resolves against the guest root, not the
      // host's working directory.
      cwd: guestWorkspacePath(guestHome, home, cwd),
      argv: const ["/bin/sh"],
    ),
    environment: {
      ..._loaderEnvironment(proot),
      "PATH": guestPath,
      "LANG": "C.UTF-8",
      // Declared rather than probed, the catalog's own word — what the model
      // is told and what a script sees agree by construction.
      packageManagerEnvVar: rootfs.packageManager,
    },
    projectHome: true,
    guestRoot: guestHome,
    includeParentEnvironment: false,
    hostToGuestPaths: hostToGuest,
    description:
        "${rootfs.describe(abi)}, in which ${rootfs.packageManager} "
        "installs anything else you need. Your home directory (~) is the "
        "project workspace, and the rest of the device is not there. "
        "It is running under proot on ${Platform.operatingSystem} "
        "${Platform.operatingSystemVersion}, so filesystem-heavy commands are "
        "slower than they look",
  );
}

/// [argv] run as a program of the Linux at [rootfsDir] rather than as a
/// shell: the same proot the driver above runs commands under, with each of
/// [shared] bound at its own host path, so a path the app hands the program
/// — its files, its data folder, a session's — is one answer inside the
/// guest and out, and [cwd], which must be under one of them, its working
/// directory. Pure, as [prootDriver] is, and for the same reason.
({List<String> command, Map<String, String> environment}) prootProgram({
  required Proot proot,
  required String rootfsDir,
  required List<String> shared,
  required String cwd,
  required List<String> argv,
}) => (
  command: _prootCommand(
    proot,
    rootfsDir,
    binds: [
      for (final dir in shared) ...["-b", "$dir:$dir"],
    ],
    cwd: cwd,
    argv: argv,
  ),
  environment: _loaderEnvironment(proot),
);

/// proot over [rootfsDir], the one command line every start in it is: what
/// every start shares around [binds] — the start's own — and then [cwd] and
/// [argv]. One list, so the terminal's shell and a CLI's program run under
/// the same proot.
List<String> _prootCommand(
  Proot proot,
  String rootfsDir, {
  List<String> readOnly = const [],
  required List<String> binds,
  required String cwd,
  required List<String> argv,
}) => [
  proot.binary,
  "-r", rootfsDir,
  "--kill-on-exit",
  "--link2symlink",
  // Root to the guest, which a package install wants and which is still the
  // app's own uid to the kernel.
  "-0",
  // What [readOnly] names is read-only on disk, and the fake root `-0`
  // grants would otherwise write through that: our patch to proot keeps it
  // from overriding a refusal, or a chmod, under these.
  for (final dir in readOnly) ...["--read-only", dir],
  "-b", "/dev",
  "-b", "/proc",
  "-b", "/sys",
  ...binds,
  "-b", "${proot.tmpDir}:/tmp",
  "-b", "${proot.resolvConf}:/etc/resolv.conf",
  "-w", cwd,
  ...argv,
];

/// What proot itself needs in its environment to start anything.
Map<String, String> _loaderEnvironment(Proot proot) => {
  "PROOT_LOADER": proot.loader,
  if (proot.loader32 != null) "PROOT_LOADER_32": proot.loader32!,
  "PROOT_TMP_DIR": proot.tmpDir,
};

/// Android's Linux as where a CLI's program runs: [prootProgram] over the
/// rootfs the Terminal settings picked, looked up at each start, so one
/// installed after launch is used and one deleted is said rather than run.
class ProotCliGuest extends LinuxCliGuest {
  ProotCliGuest({
    required this.proot,
    required this.store,
    required this.rootfsId,
  });

  final Proot proot;
  final RootfsStore store;
  final String? Function() rootfsId;

  /// The device's own: proot runs the guest's programs natively.
  @override
  Abi get abi => Abi.current();

  /// Started as a process of this device, under proot.
  @override
  Future<CliProcess> spawn(
    List<String> argv, {
    required String cwd,
    required Map<String, String> environment,
    required List<String> shared,
  }) {
    final rootfs = rootfsById(rootfsId());
    final dir = rootfs == null ? null : store.directoryOfSync(rootfs.id);
    if (dir == null) {
      throw LlmException(
        "No Linux is installed to run it in. Install one from the Terminal "
        "settings.",
      );
    }
    final (:command, environment: own) = prootProgram(
      proot: proot,
      rootfsDir: dir,
      shared: shared,
      cwd: cwd,
      argv: argv,
    );
    return launchProcess(
      command.first,
      command.sublist(1),
      workingDirectory: cwd,
      environment: {...environment, ...own},
    );
  }

  /// By the picked Linux's own package manager; `apk` is the one the
  /// catalog has, and a Linux that declares another is said rather than
  /// handed a command it has no program for.
  @override
  List<String> install(List<String> packages) =>
      switch (rootfsById(rootfsId())?.packageManager) {
        "apk" => ["apk", "add", "--no-cache", ...packages],
        final other => throw LlmException(
          "Installing ${packages.join(", ")} with ${other ?? "no Linux"} is "
          "not something Entoli knows how to do.",
        ),
      };
}
