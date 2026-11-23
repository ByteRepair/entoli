import "dart:async";
import "dart:io";
import "dart:isolate";

import "package:ffi/ffi.dart";
import "package:path/path.dart" as p;
import "package:entoli_core/model/builtin_project.dart";
import "package:entoli_core/model/config.dart";
import "package:entoli_core/model/confinement.dart";
import "package:entoli_core/model/download.dart";
import "package:entoli_core/model/read_only_dirs.dart";
import "package:entoli_core/model/rootfs.dart";
import "package:entoli_core/model/rootfs_store.dart";
import "package:entoli_core/model/shell.dart";

import "bundled_tools.dart";
import "cli_guest.dart";
import "file_modes.dart";
import "file_rootfs_store.dart";
import "ish_ffi.dart";
import "ish_pipe.dart";
import "ish_shell.dart";
import "landlock.dart";
import "local_shell.dart";
import "proot.dart";
import "seatbelt.dart";
import "tree_ops.dart";

export "bundled_tools.dart" show BundledTools;
export "cli_guest.dart";
export "file_modes.dart" show makeExecutable;
export "local_shell.dart" show LocalShell, environmentWithoutAppImage;
export "sandbox_grants.dart" show MachineSandboxFolders;
export "tree_ops.dart" show removeTree;

/// The shell commands run in: the emulator on iOS, this machine or the
/// picked Linux under proot everywhere else, through [driver].
Shell platformShell({
  required Map<String, String> Function() environment,
  required ShellDriver? Function({String? project}) driver,
  String? dataDir,
  RootfsStore? rootfsStore,

  /// Asked per command: which Linux the settings page has picked. Null where
  /// the platform has no picker at all.
  String? Function()? rootfsId,

  /// Where the guest's natively run tools live on iOS; see `HostTools`.
  String? hostToolsDir,
}) {
  if (Platform.isIOS) {
    // No host shell and no proot: IshShell drives the emulator through FFI,
    // resolving the rootfs per command; the guest boots once, so a swap after
    // the first command is refused until a restart. See ios/AGENTS.md.
    String? rootfsDir() {
      final rootfs = rootfsById(rootfsId?.call());
      return rootfs != null ? rootfsStore?.directoryOfSync(rootfs.id) : null;
    }

    return IshShell(
      rootfsDir: () => rootfsDir() ?? "",
      dataDir: dataDir ?? "",
      environment: environment,
      hostToolsDir: hostToolsDir,
      // Asked per session, since the setting is picked after startup.
      transport: () => IshWorker(core: ishCoreOf(rootfsById(rootfsId?.call()))),
      platformDescription: () => rootfsDir() != null
          ? rootfsById(rootfsId?.call())!.describe(EmulatedLinux.key)
          : "iOS, with no Linux installed. Install one from the Terminal "
                "settings to run commands.",
    );
  }
  return LocalShell(
    environment: environment,
    driver: driver,
    withoutDriver: Platform.isAndroid
        ? "Android, with no Linux installed. Install one from the Terminal "
              "settings to run commands."
        : null,
  );
}

/// What the next command runs under: the picked Linux where it is installed
/// and this build carries proot, else the machine itself — except on Android,
/// where it is the Linux or nothing. Synchronous because it is asked before
/// every command.
///
/// On the machine itself, a rootfs-isolated built-in project's bin directory
/// is prefixed onto `PATH`; a user-set `PATH` in the command environment still
/// wins over it.
ShellDriver? platformDriver({
  required String defaultSkillsBundledDir,
  required String defaultUserSkillsDir,
  String? projectSkillsBundledDir,
  String? projectUserSkillsDir,
  Toolset? tools,
  Proot? proot,
  RootfsStore? store,
  String? rootfsId,
  String? abi,
  String? project,
  AppConfig? config,
  String? byteRepairBinDir,

  /// The login shell's PATH, captured once per run ([captureLoginPath]): the
  /// driver is resolved synchronously, so the capture cannot happen here.
  String? loginPath,
}) {
  final rootfs = rootfsById(rootfsId);
  final baseDir = rootfs != null && store != null
      ? store.directoryOfSync(rootfs.id)
      : null;
  if (rootfs != null && proot != null && baseDir != null) {
    // proot refuses a binding whose host path is missing ("can't sanitize
    // binding"), and a project's skill dirs exist only after a setup or a
    // first turn. The default project's two are always there.
    String? bindIfThere(String? path) =>
        path != null && Directory(path).existsSync() ? path : null;
    return prootDriver(
      proot: proot,
      rootfs: rootfs,
      rootfsDir: baseDir,
      defaultSkillsBundledDir: defaultSkillsBundledDir,
      defaultUserSkillsDir: defaultUserSkillsDir,
      projectSkillsBundledDir: bindIfThere(projectSkillsBundledDir),
      projectUserSkillsDir: bindIfThere(projectUserSkillsDir),
      abi: abi,
    );
  }
  // Android's own shell is not offered: it has no /bin, its toybox is not
  // what the model expects, and the CLIs and package installs everything
  // else leans on live in the Linux. With none installed there is no
  // terminal, as on iOS, and the first-run setup is what installs one.
  if (Platform.isAndroid) return null;
  return LocalShell.hostDriver(
    tools: tools,
    environment:
        project != null &&
            builtinProjectOf(project)?.requiresSetup == true &&
            byteRepairBinDir != null
        ? {
            "PATH":
                "$byteRepairBinDir${LocalShell.listSeparator()}"
                "${loginPath ?? Platform.environment["PATH"] ?? ""}",
          }
        : null,
    sandboxHelper: Platform.isLinux && config != null
        ? LandlockSandboxHelper(cacheDir: landlockCacheDir(config))
        : Platform.isMacOS
        ? SeatbeltSandboxHelper()
        : null,
    // A desktop launch's inherited PATH misses what the user's profile adds
    // (`~/.local/bin`); null leaves the inherited one standing.
    loginPath: loginPath,
  );
}

/// Where the Landlock helper is compiled: the data directory rather than the
/// OS cache, so a cache clear does not cost the compile again.
String landlockCacheDir(AppConfig config) => p.join(config.dataDir, "landlock");

/// The device's ABI, which only Android answers: what proot runs, and which
/// image of a distribution it downloads.
Future<String?> deviceAbi() =>
    Platform.isIOS ? Future.value(null) : BundledTools.abi();

/// How this device runs a Linux: under the emulator on iOS, under proot on
/// an Android whose build carries it for [abi], and in the machine's own
/// shell on a desktop.
LinuxHost linuxHostOf({String? abi, Toolset? tools}) => Platform.isIOS
    ? const EmulatedLinux()
    : abi == null
    ? const NoLinux()
    : tools?.proot != null
    ? ProotLinux(abi)
    : MissingProotLinux(abi);

/// Where a CLI provider's program runs on a device with [linux]: this
/// machine on a desktop, the picked Linux under proot on Android and in the
/// emulator on iOS, and nowhere on an Android build with no proot in it.
CliGuest? cliGuestOf(
  LinuxHost linux, {
  Proot? proot,
  required RootfsStore store,
  required String? Function() rootfsId,
  required String dataDir,
  String? loginPath,
}) => switch (linux) {
  NoLinux() => HostCliGuest(loginPath: loginPath),
  ProotLinux() when proot != null => ProotCliGuest(
    proot: proot,
    store: store,
    rootfsId: rootfsId,
  ),
  ProotLinux() || MissingProotLinux() => null,
  // The x86-64 guest runs only a Linux built for it, so a picked one this
  // device is not offered — an i386 Alpine kept from before — is none.
  EmulatedLinux() => IshCliGuest(
    rootfsDir: () {
      final rootfs = rootfsById(rootfsId());
      return rootfs != null && linux.catalog.contains(rootfs)
          ? store.directoryOfSync(rootfs.id)
          : null;
    },
    dataDir: dataDir,
  ),
};

/// What keeps the host shell's commands in. Linux's is the Landlock helper
/// [platformDriver] is built with, macOS's the Seatbelt one; a phone's is the
/// OS's own app sandbox.
Confinement hostConfinement() => Platform.isLinux
    ? Confinement.landlock
    : Platform.isMacOS
    ? Confinement.seatbelt
    : Platform.isAndroid || Platform.isIOS
    ? Confinement.appSandbox
    : Confinement.none;

/// The downloaded Linuxes, under `<cacheDir>/rootfs`, fetched by [download].
/// On iOS the unpack is iSH's fakefsify, not the system tar, which the exec
/// ban denies.
RootfsStore openRootfsStore(String cacheDir, StartDownload download) =>
    Platform.isIOS
    ? FileRootfsStore(
        p.join(cacheDir, "rootfs"),
        download: download,
        tar: _ishFakefsify,
      )
    : FileRootfsStore(p.join(cacheDir, "rootfs"), download: download);

/// Where the tools an emulated guest hands the host live: `HostTools`.
String hostToolsDirIn(String cacheDir) => p.join(cacheDir, "host-tools");

/// Lays out the tools this build ships for the device's ABI (Android only),
/// under the cache dir: rebuilt from the APK on demand, so a backup must not
/// carry its symlinks.
Future<Toolset?> installBundledTools(String cacheDir) async {
  if (!Platform.isAndroid) return null;
  final libDir = await BundledTools.nativeLibraryDir();
  if (libDir == null) return null;
  return BundledTools.install(root: p.join(cacheDir, "tools"), libDir: libDir);
}

/// The user's login shell's PATH, or null to keep the inherited one. Only
/// bash and zsh are asked, their profile syntax being known; a profile that
/// prints anything else is why the last non-empty line is read.
Future<String?> captureLoginPath() async {
  final home = LocalShell.machineHomeDir();
  final login = Platform.environment["SHELL"];
  if (home == null || login == null) return null;
  if (!(login.endsWith("/bash") || login == "bash" || login.endsWith("/zsh"))) {
    return null;
  }
  if (!File(login).existsSync()) return null;
  try {
    final process = await Process.start(
      login,
      ["-l", "-c", r'echo "$PATH"'],
      environment: {"HOME": home, "PATH": "/usr/bin:/bin"},
      includeParentEnvironment: false,
    );
    final stdout = process.stdout.transform(systemEncoding.decoder).join();
    unawaited(process.stderr.drain<void>());
    final int code;
    try {
      code = await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // A profile that waits on input would otherwise be left running.
      process.kill(ProcessSignal.sigkill);
      return null;
    }
    if (code != 0) return null;
    final lines = (await stdout)
        .split("\n")
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    final path = lines.last;
    return path.contains("/") ? path : null;
  } on Exception {
    return null;
  }
}

/// iOS's rootfs unpack: iSH's `fakefsify` in-process (iOS denies a child
/// process for `tar`). The FFI call blocks, so it runs on its own isolate.
Future<ProcessResult> _ishFakefsify(String archive, String into) =>
    Isolate.run(() {
      final fn = ishFakefsifyFn;
      if (fn == null) {
        return ProcessResult(
          1,
          1,
          "",
          "iSH fakefsify is not linked into this build.",
        );
      }
      final archivePtr = archive.toNativeUtf8();
      final intoPtr = into.toNativeUtf8();
      try {
        final rc = fn(archivePtr, intoPtr);
        return rc == 0
            ? ProcessResult(0, 0, "", "")
            : ProcessResult(1, rc, "", "fakefsify failed (errno $rc)");
      } finally {
        malloc.free(archivePtr);
        malloc.free(intoPtr);
      }
    });

/// The app's read-only directories, one manager per path. See
/// `model/read_only_dirs.dart` in the core.
final readOnlyDirs = ReadOnlyDirs(setTreeWritable);

/// Deletes a tree that may hold proot's mode-0000 bind stubs, which a plain
/// recursive delete cannot list. The restore clear needs it: the stubs sit
/// deep inside `projects/<project>/rootfs/`.
Future<void> deleteTree(String path) async {
  // removeTree's own `chmod` is a process, which iOS refuses, and Windows'
  // read-only attribute is not a mode at all; elsewhere it unlocks the tree
  // itself, and a second walk would be one more pass over a whole rootfs.
  if (Platform.isIOS || Platform.isWindows) {
    await setTreeWritable([path], writable: true);
  }
  final err = await removeTree(path);
  if (err != null) throw Exception("could not delete $path: $err");
}
