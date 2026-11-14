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
/// "Byte Repair's environment, in five variables" in the directory's
/// AGENTS.md.
///
/// "Run Setup" installs into the selected shared guest environment (or the
/// desktop host), then writes the `.setup-complete` marker the chat page gates
/// the composer on.
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
    this.scratchDir,
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

  /// The shared installed rootfs, used for guest imports and package metadata.
  final RootfsStore? rootfsStore;

  /// [homebrewPaths], or a test's own.
  final List<String> brewPaths;

  /// Where ESBMC is fetched and unpacked (`ENV_SCRATCH_DIR`); null is beside
  /// [installDir]. See "Tools the host runs" in ios/AGENTS.md.
  final String? scratchDir;

  static const tools = {"ESBMC": "esbmc", "make": "make", "gh": "gh"};

  Future<ShellResult> _run(
    Shell shell,
    String script,
    Duration timeout, {
    Map<String, String>? environment,
    void Function(String output)? onOutput,
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
      if (onOutput != null) watchShellOutput(run, onOutput);
      return await run.result;
    } catch (e) {
      logFailure("byte-repair", "shell run failed", e);
      return ShellResult.failed(e.toString());
    }
  }

  /// Writes the `.setup-complete` marker that lifts the chat page's gate.
  Future<void> markSetupComplete() async {
    // Recursive: setup can run before any byte-repair chat has made the
    // project's directory.
    final marker = File(config.setupCompleteFile(project: project))
      ..createSync(recursive: true);
    marker.writeAsStringSync("done");
  }

  /// The bundled install script through [shell], then the marker on success.
  /// [onOutput] hears what it has printed so far, each time that grows.
  Future<ShellResult> install(
    Shell shell, {
    void Function(String output)? onOutput,
  }) async {
    final body = await rootBundle.loadString(
      "assets/scripts/byte-repair-setup.sh",
    );
    final result = await _run(
      shell,
      body,
      installTimeout,
      environment: installEnvironment(),
      onOutput: onOutput,
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
      "ENV_SCRATCH_DIR": ?scratchDir,
      if (_usesHomebrew) packageManagerEnvVar: "brew",
      if (_usesHomebrew && _brew != null) "ENV_BREW": _brew!,
    };
  }

  /// Copies a user-picked ESBMC binary next to the tools the setup fetched,
  /// making it executable. The selected shared rootfs must already be
  /// installed. Null on success, an error message on failure.
  Future<String?> importEsbmc(XFile file) async {
    // The shared guest rootfs is not host-accessible on iSH, but is a regular
    // tree on Android. Desktop installs use the app's bin directory.
    final destDirPath = isPhone ? _guestEsbmcDir : _hostInstallDir;
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

  /// Deletes this project's setup data, workspace and marker, plus desktop
  /// tools. Shared guest packages remain installed for other projects. Null on
  /// success, an error message on failure.
  Future<String?> deleteEnvironment() async {
    final errors = await Future.wait([
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
    // On a phone the rootfs pick is the gate: with no Linux there is no
    // shell to run anything in, on Android as on iOS. The target, not
    // `Platform`, so the section's fixtures can name their platform.
    if (isPhone) {
      if (AppSettings.load(config).rootfsId != null) return null;
      return "Byte Repair needs a Linux to run in, and this device has none "
          "installed. Please install one from the Terminal settings.";
    }
    return installDir == null ? noInstallDestination : null;
  }

  /// What [deleteEnvironment] clears beyond the workspace, for the confirm
  /// dialog, read off the disk: null where the setup left no host tree.
  String? get environmentDeletion {
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

  /// `/usr/local/bin` inside the shared selected rootfs, or null where it is
  /// not installed.
  String? get _guestEsbmcDir {
    final id = AppSettings.load(config).rootfsId;
    final dir = id == null ? null : rootfsStore?.directoryOfSync(id);
    return dir == null ? null : p.join(dir, "usr", "local", "bin");
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
