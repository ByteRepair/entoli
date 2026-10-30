import "dart:io";

import "package:file_selector/file_selector.dart";
import "package:flutter/services.dart" show rootBundle;
import "package:path/path.dart" as p;

import "../../core/config.dart";
import "../../core/log.dart";
import "../../core/platform/form_factor.dart";
import "../../domain/app_settings.dart";
import "../../domain/rootfs.dart";
import "../../domain/rootfs_store.dart";
import "../../domain/shell.dart";
import "tree_ops.dart";

/// Installs and queries the Byte Repair tooling — make, github-cli and ESBMC —
/// so they are on PATH for every agent turn in the project. The install runs
/// through the configured terminal env with [project]: a guest's rootfs on
/// Android and iOS, the host shell with an injected bin directory on the
/// desktops. The script is told its environment and probes nothing — see
/// "Byte Repair's environment, in four variables" in the directory's
/// AGENTS.md.
///
/// "Run Setup" owns the lifecycle: copy the base rootfs into the project (for
/// a project that opts into rootfs isolation), run the script, write the
/// `.setup-complete` marker the chat page gates the composer on.
///
class ByteRepairStore {
  ByteRepairStore({
    required this.config,
    required this.project,
    required this.workspace,
    this.installDir,
    this.installTimeout = guestInstallTimeout,
    this.rootfsStore,
    this.brewPaths = homebrewPaths,
  });

  final AppConfig config;
  final String project;
  final String workspace;

  /// Where the script puts the tools, sent as `ENV_INSTALL_DIR`:
  /// [guestEsbmcInstallDir] inside a guest, the app's bin directory on the
  /// desktops, null where there is nowhere to put them. The guest
  /// path is also how host-side readers know nothing is on the host's disk.
  final String? installDir;

  final Duration installTimeout;

  /// The base rootfs a copy is made from. Null where there is none.
  final RootfsStore? rootfsStore;

  /// [homebrewPaths], or a test's own.
  final List<String> brewPaths;

  static const tools = {"ESBMC": "esbmc", "make": "make", "gh": "gh"};

  Future<ShellResult> _run(
    Shell shell,
    String script,
    Duration timeout, {
    Map<String, String>? environment,
  }) async {
    try {
      final run = shell.start(
        script,
        cwd: workspace,
        home: workspace,
        timeout: timeout,
        oneShot: true,
        project: project,
        environment: environment,
      );
      return await run.result;
    } catch (e) {
      logFailure("byte-repair", "shell run failed", e);
      return ShellResult.failed(e.toString());
    }
  }

  /// Copies the base rootfs into the project's data directory, for a project
  /// that opted into rootfs isolation. A no-op where no rootfs is selected;
  /// an error string where it cannot.
  Future<String?> ensureRootfs() async {
    // The copy is the proot guest's filesystem: off Android nothing reads it,
    // and a rootfsId left over from another device must not pay for one.
    if (!Platform.isAndroid) return null;
    final id = AppSettings.load(config).rootfsId;
    if (id == null || rootfsStore == null) return null;
    final baseDir = rootfsStore!.directoryOfSync(id);
    if (baseDir == null) {
      return "No rootfs is installed. Download one from Terminal settings.";
    }
    final target = config.projectRootfsDir(project: project, rootfsId: id);
    if (_rootfsComplete(target).existsSync()) return null;
    final err = await copyTree(baseDir, target);
    if (err != null) {
      logFailure("byte-repair", "rootfs copy failed", err);
      return "Failed to copy rootfs: $err";
    }
    _rootfsComplete(target).writeAsStringSync(id);
    return null;
  }

  /// Writes the `.setup-complete` marker that lifts the chat page's gate.
  Future<void> markSetupComplete() async {
    // Recursive: setup can run before any byte-repair chat has made the
    // project's directory.
    final marker = File(config.setupCompleteFile(project: project))
      ..createSync(recursive: true);
    marker.writeAsStringSync("done");
  }

  /// [ensureRootfs], then the bundled install script through [shell], then
  /// the marker on success.
  Future<ShellResult> install(Shell shell) async {
    final err = await ensureRootfs();
    if (err != null) return ShellResult.failed(err);
    final body = await rootBundle.loadString(
      "assets/scripts/byte-repair-setup.sh",
    );
    final result = await _run(
      shell,
      body,
      installTimeout,
      environment: installEnvironment(),
    );
    if (result.returnCode == 0) await markSetupComplete();
    return result;
  }

  /// The install run's environment, over its driver's: the destination, and
  /// in a guest the picked rootfs's package manager. The host has none of
  /// ours to name.
  Map<String, String> installEnvironment() {
    final rootfs = rootfsById(AppSettings.load(config).rootfsId);
    return {
      "ENV_INSTALL_DIR": installDir ?? "",
      if (installDir == guestEsbmcInstallDir && rootfs != null)
        packageManagerEnvVar: rootfs.packageManager,
      "ENV_ESBMC_BINARY": esbmcFileName,
      if (_usesHomebrew) packageManagerEnvVar: "brew",
      if (_usesHomebrew && _brew != null) "ENV_BREW": _brew!,
    };
  }

  /// Copies a user-picked ESBMC binary next to the tools the setup fetched,
  /// making it executable. The rootfs must already exist — run [install]
  /// first. Null on success, an error message on failure.
  Future<String?> importEsbmc(XFile file) async {
    // Where an install lands: the proot guest's rootfs copy on Android, the
    // bin directory on a desktop. iSH's filesystem is the emulator's fakefs,
    // which no host path reaches.
    final destDirPath = Platform.isAndroid ? _guestEsbmcDir : _hostInstallDir;
    if (destDirPath == null) {
      return Platform.isIOS
          ? "Importing an ESBMC binary is not possible inside the iSH "
                "guest: its filesystem is the emulator's own, not a path "
                "dart:io can write."
          : "The Byte Repair rootfs has not been set up yet. Run Setup first.";
    }
    try {
      final destDir = Directory(destDirPath);
      await destDir.create(recursive: true);
      final dest = p.join(destDir.path, esbmcFileName);
      await File(dest).writeAsBytes(await file.readAsBytes());
      if (!Platform.isWindows) await Process.run("chmod", ["+x", dest]);
      return null;
    } catch (e) {
      logFailure("byte-repair", "import ESBMC failed", e);
      return e.toString();
    }
  }

  /// Deletes the environment: the per-project rootfs copy (Android) or the
  /// fetched tools (desktops), plus the workspace and the marker. An iSH
  /// guest's installs live in the base Alpine and go with Terminal settings'
  /// rootfs delete instead. Null on success, an error message on failure.
  Future<String?> deleteEnvironment() async {
    final errors = await Future.wait([
      removeTree(_rootfsTree),
      removeTree(config.projectWorkspaceDir(project: project)),
      if (_hostInstallDir != null) removeTree(p.dirname(_hostInstallDir!)),
    ]);
    final err = errors.where((e) => e != null).firstOrNull;
    if (err != null) {
      logFailure("byte-repair", "delete environment failed", err);
      return err;
    }
    try {
      final marker = File(config.setupCompleteFile(project: project));
      if (marker.existsSync()) await marker.delete();
      return null;
    } catch (e) {
      logFailure("byte-repair", "delete environment failed", e);
      return e.toString();
    }
  }

  /// The delete confirm's message.
  String get deleteConfirmMessage {
    final environment = environmentDeletion;
    final tail = capabilityBanner == null
        ? " Run Setup to use Byte Repair again."
        : "";
    return environment == null
        ? "This deletes the Byte Repair workspace (cloned repos, scratch "
              "files) and all chats in the project.$tail"
        : "This deletes $environment, the Byte Repair workspace (cloned "
              "repos, scratch files), and all chats in the project.$tail";
  }

  /// The first line of `<command> --version`, or null where it is not
  /// installed or the call failed.
  Future<String?> runToolVersion(Shell shell, String command) async {
    final result = await _run(
      shell,
      "$command --version",
      const Duration(seconds: 15),
    );
    if (result.returnCode == 0) return result.output.trim().split("\n").first;
    // Not installed is the expected answer here — the version poll is how the
    // settings page detects it — so it is quiet; only a call that failed to
    // run at all gets a line.
    if (result.exceptionInfo != null) {
      logFailure(
        "byte-repair",
        "$command --version failed",
        result.exceptionInfo,
      );
    }
    return null;
  }

  /// Each of [tools] by name, to its version or null where not installed.
  Future<Map<String, String?>> runToolVersions(Shell shell) async {
    final entries = await Future.wait(
      tools.entries.map(
        (e) async => MapEntry(e.key, await runToolVersion(shell, e.value)),
      ),
    );
    return Map.fromEntries(entries);
  }

  /// The installed `brew`, or null where Homebrew is not installed.
  String? get _brew =>
      brewPaths.where((path) => File(path).existsSync()).firstOrNull;

  /// A mac's host setup installs with Homebrew, the one way to an ESBMC that
  /// starts there: the release's mac binary is linked against Homebrew's z3,
  /// mpfr, gmp, boost and llvm and ships none of them. The target, not
  /// `Platform`, like [capabilityBanner].
  bool get _usesHomebrew => isMac && _hostInstallDir != null;

  /// What a setup does to the machine beyond the app's own directories, for
  /// the line above Run Setup: null where it installs nowhere else.
  String? get setupNotice => _usesHomebrew
      ? "On this Mac, Run Setup uses Homebrew to install whichever of make, "
            "GitHub CLI and ESBMC are missing. They are installed into the "
            "system, not the app, so deleting the Byte Repair data leaves them "
            "installed."
      : null;

  /// What the user has to install before a setup can work — a line saying
  /// so and the command to paste into a terminal, shown under the notice with
  /// a copy button — or null where nothing is missing. The setup cannot run
  /// it itself: Homebrew's installer asks for a password through sudo.
  ({String why, String command})? get prerequisite =>
      _usesHomebrew && _brew == null
      ? (
          why:
              "Homebrew is not installed. Paste this into a terminal and "
              "run it, then press Run Setup:",
          command: homebrewInstallCommand,
        )
      : null;

  /// Why this environment cannot run a setup, or null where it can.
  String? get capabilityBanner {
    // On a guest platform the rootfs pick is the gate: a "Host" env has no
    // package manager on Android and no shell at all on iOS. The target, not
    // `Platform`, so the section's fixtures can name their platform.
    if (isPhone) {
      if (AppSettings.load(config).rootfsId != null) return null;
      return isAndroid
          ? 'Byte Repair does not work when using the "Host" terminal '
                "environment on this device. Please choose another terminal "
                "environment."
          : 'Byte Repair does not work when using the "Host" terminal '
                "environment on this platform, which has no shell to run "
                "anything in. Please install a Linux from the Terminal "
                "settings.";
    }
    return installDir == null ? noInstallDestination : null;
  }

  /// What [deleteEnvironment] clears beyond the workspace, for the confirm
  /// dialog, read off the disk: null where the setup left no host tree.
  String? get environmentDeletion {
    if (Directory(_rootfsTree).existsSync()) {
      return "the Byte Repair rootfs (the Linux copy and everything "
          "installed into it)";
    }
    if (_hostInstallDir != null && Directory(_hostInstallDir!).existsSync()) {
      return _usesHomebrew
          ? "the links the setup made to Homebrew's tools (Homebrew keeps "
                "what it installed)"
          : "the tools the setup fetched into the app's cache directory";
    }
    return null;
  }

  /// The host tree an install creates, or null where [installDir] is the
  /// guest's own `/usr/local/bin`, a path inside the Linux.
  String? get _hostInstallDir =>
      installDir == guestEsbmcInstallDir ? null : installDir;

  /// Every per-project rootfs copy.
  String get _rootfsTree =>
      p.join(config.projectDir(project: project), "rootfs");

  /// `/usr/local/bin` inside the selected rootfs's project copy, or null
  /// where setup has not made the copy yet.
  String? get _guestEsbmcDir {
    final id = AppSettings.load(config).rootfsId;
    if (id == null) return null;
    final dir = config.projectRootfsDir(project: project, rootfsId: id);
    return _rootfsComplete(dir).existsSync()
        ? p.join(dir, "usr", "local", "bin")
        : null;
  }
}

/// How long a setup may run: a guest's `apk` is quick, where a host install
/// fetches a 240 MB ESBMC release zip.
const guestInstallTimeout = Duration(minutes: 10);
const hostInstallTimeout = Duration(minutes: 30);

/// Where a guest's install script lands its tools.
const guestEsbmcInstallDir = "/usr/local/bin";

/// The banner where there is nowhere to install the tools.
const noInstallDestination =
    "Byte Repair does not work on this platform: "
    "there is nowhere to install the tools it sets up.";

/// The name ESBMC lands under in a bin directory. The setup script installs
/// under it and the setup gate checks for it, so both agree by asking here.
final String esbmcFileName = Platform.isWindows ? "esbmc.exe" : "esbmc";

/// Homebrew's own install command, the one brew.sh gives. A mac's setup
/// installs with Homebrew and cannot install Homebrew itself: the installer
/// asks for an administrator's password through sudo, and the setup runs with
/// no terminal to type it into.
const homebrewInstallCommand =
    '/bin/bash -c "\$(curl -fsSL '
    'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"';

/// Where Homebrew's installer puts `brew`: Apple silicon's prefix, then
/// Intel's. The only two it supports, so asking them is asking whether it is
/// installed.
const homebrewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"];

/// The marker a finished rootfs copy at [dir] carries, naming its rootfs.
File _rootfsComplete(String dir) => File(p.join(dir, ".complete"));
