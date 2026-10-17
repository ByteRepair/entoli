import "package:file_selector/file_selector.dart";
import "package:flutter/services.dart" show rootBundle;

import "../../core/config.dart";
import "../../core/log.dart";
import "../../domain/app_settings.dart";
import "../../domain/rootfs.dart";
import "../../domain/rootfs_store.dart";
import "../../domain/shell.dart";

/// Installs and queries the Byte Repair tooling — make, github-cli and ESBMC —
/// so they are on PATH for every agent turn in the project. The install runs
/// through the configured terminal env with [project]: a guest's rootfs on
/// Android and iOS, the host shell with an injected bin directory on the
/// desktops. The script is told its environment and probes nothing — see
/// "Byte Repair's environment, in three variables" in the directory's
/// AGENTS.md.
///
/// "Run Setup" owns the lifecycle: copy the base rootfs into the project (for
/// a project that opts into rootfs isolation), run the script, write the
/// `.setup-complete` marker the chat page gates the composer on.
///
/// Split like `RootfsStore`/`FileRootfsStore` so the type is nameable where
/// `dart:io` is not compiled: the shell-driven halves live here, the
/// filesystem halves in [FileByteRepairStore] and [UnavailableByteRepairStore].
abstract class ByteRepairStore {
  ByteRepairStore({
    required this.config,
    required this.project,
    required this.workspace,
    this.installDir,
    this.installTimeout = guestInstallTimeout,
    this.rootfsStore,
  });

  final AppConfig config;
  final String project;
  final String workspace;

  /// Where the script puts the tools, sent as `ENV_INSTALL_DIR`:
  /// [guestEsbmcInstallDir] inside a guest, the app's bin directory on the
  /// desktops, null where no shell could run the script (the web). The guest
  /// path is also how host-side readers know nothing is on the host's disk.
  final String? installDir;

  final Duration installTimeout;

  /// The base rootfs a copy is made from. Null on the web platform.
  final RootfsStore? rootfsStore;

  static const tools = {"ESBMC": "esbmc", "make": "make", "gh": "gh"};

  Future<ShellResult> _run(Shell shell, String script, Duration timeout,
      {Map<String, String>? environment}) async {
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
  Future<String?> ensureRootfs();

  /// Writes the `.setup-complete` marker that lifts the chat page's gate.
  Future<void> markSetupComplete();

  /// [ensureRootfs], then the bundled install script through [shell], then
  /// the marker on success.
  Future<ShellResult> install(Shell shell) async {
    final err = await ensureRootfs();
    if (err != null) return ShellResult.failed(err);
    final body = await rootBundle.loadString("assets/scripts/byte-repair-setup.sh");
    final result = await _run(shell, body, installTimeout,
        environment: installEnvironment());
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
    };
  }

  /// Copies a user-picked ESBMC binary next to the tools the setup fetched,
  /// making it executable. The rootfs must already exist — run [install]
  /// first. Null on success, an error message on failure.
  Future<String?> importEsbmc(XFile file);

  /// Deletes the environment: the per-project rootfs copy (Android) or the
  /// fetched tools (desktops), plus the workspace and the marker. An iSH
  /// guest's installs live in the base Alpine and go with Terminal settings'
  /// rootfs delete instead. Null on success, an error message on failure.
  Future<String?> deleteEnvironment();

  /// What [deleteEnvironment] clears beyond the workspace, for the confirm
  /// dialog, read off the disk: null where the setup left no host tree.
  String? get environmentDeletion;

  /// Why this environment cannot run a setup, or null where it can. Answered
  /// here rather than in the widget, whose `defaultTargetPlatform` on the web
  /// is the phone the browser runs on.
  String? get capabilityBanner;

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
    final result = await _run(shell, "$command --version", const Duration(seconds: 15));
    if (result.returnCode == 0) return result.output.trim().split("\n").first;
    // Not installed is the expected answer here — the version poll is how the
    // settings page detects it — so it is quiet; only a call that failed to
    // run at all gets a line.
    if (result.exceptionInfo != null) {
      logFailure("byte-repair", "$command --version failed", result.exceptionInfo);
    }
    return null;
  }

  /// Each of [tools] by name, to its version or null where not installed.
  Future<Map<String, String?>> runToolVersions(Shell shell) async {
    final entries = await Future.wait(
      tools.entries.map((e) async => MapEntry(e.key, await runToolVersion(shell, e.value))),
    );
    return Map.fromEntries(entries);
  }
}

/// How long a setup may run: a guest's `apk` is quick, where a host install
/// fetches a 240 MB ESBMC release zip.
const guestInstallTimeout = Duration(minutes: 10);
const hostInstallTimeout = Duration(minutes: 30);

/// Where a guest's install script lands its tools.
const guestEsbmcInstallDir = "/usr/local/bin";

/// The banner where there is nowhere to install the tools.
const noInstallDestination = "Byte Repair does not work on this platform: "
    "there is nowhere to install the tools it sets up.";

/// The web's store: no filesystem to copy a rootfs onto and no shell to run
/// the install script in, so every io-side operation answers with an error
/// rather than failing obscurely. Setup reads as complete (see
/// `platformSetupComplete`), so the chat page never gates on a marker nothing
/// could write.
class UnavailableByteRepairStore extends ByteRepairStore {
  UnavailableByteRepairStore({
    required super.config,
    required super.project,
    required super.workspace,
  });

  static const _why =
      "Byte Repair needs a terminal environment, which this platform does not have.";

  @override
  Future<String?> ensureRootfs() async => _why;

  @override
  Future<void> markSetupComplete() async {}

  @override
  Future<String?> importEsbmc(XFile file) async => _why;

  @override
  Future<String?> deleteEnvironment() async => _why;

  @override
  String? get environmentDeletion => null;

  @override
  String? get capabilityBanner => noInstallDestination;
}