import "package:file_selector/file_selector.dart";
import "package:flutter/services.dart" show rootBundle;

import "../../core/config.dart";
import "../../core/log.dart";
import "../../domain/rootfs_store.dart";
import "../../domain/shell.dart";

/// Installs and queries the Byte Repair tooling — make, github-cli and ESBMC —
/// so they are on PATH for every agent turn in the project. The install runs
/// through the configured terminal env (proot rootfs on Android, the host
/// shell on the desktops, with a bin directory to inject on every desktop)
/// with [project], so it reaches the project's own rootfs instance or the
/// injected bin directory.
///
/// The script's environment is declared by the caller, never probed by the
/// script: [installDir] is where tools land (`/usr/local/bin` inside a guest,
/// `<cacheDir>/byte-repair/bin` on the host), sent as `ENV_INSTALL_DIR` by
/// [installEnvironment]; the driver's environment carries
/// `ENV_PACKAGE_MANAGER` (`apk` in a guest, nothing on the host, where the
/// machine's package manager is not ours to touch and static binaries are
/// fetched instead), and the io side's [installEnvironment] adds the binary's
/// name, which the script does not probe — the one encoding of it lives with
/// the gate that asks for the file it names. A binary already on PATH *and
/// runnable* is never re-fetched — the script copies it into the bin
/// directory instead; see "Byte Repair's environment, in three variables" in
/// the directory's AGENTS.md.
///
/// "Run Setup" owns the full lifecycle: it copies the base rootfs from cache
/// into the project's data directory (for a project that opts into rootfs
/// isolation), runs the install script, and writes a `.setup-complete` marker.
/// The turn path no longer creates the rootfs copy — it relies on setup having
/// been run, and the chat page gates the composer on that marker.
///
/// Split the way `RootfsStore`/`FileRootfsStore` are, for the same reason: the
/// type has to be nameable where `dart:io` is not compiled, so the shell-driven
/// halves live here and the filesystem halves — the rootfs copy, the ESBMC
/// import, the environment delete, the markers — are [FileByteRepairStore]'s on
/// io and [UnavailableByteRepairStore]'s on the web.
abstract class ByteRepairStore {
  ByteRepairStore({
    required this.config,
    required this.project,
    required this.workspace,
    this.installDir,
    this.installTimeout = _guestInstallTimeout,
    this.rootfsStore,
  });

  final AppConfig config;
  final String project;
  final String workspace;

  /// Where the install script puts the tools it fetches: the rootfs's own
  /// `/usr/local/bin` inside a guest, the app's bin directory on the
  /// desktops. Always set where an install can run — the script refuses to
  /// guess a destination itself. Null where there is nothing to point at — a
  /// guest reaches its own `/usr/local/bin` without help, iOS's iSH guest
  /// has no release to match, and the web has no shell — so a null here is
  /// "no host install", never a path the script may guess around.
  final String? installDir;

  /// How long the install script may run. Thirty minutes on the host, where
  /// ESBMC is a 240 MB release zip over the network; ten inside a guest,
  /// where apk is a local package manager. Chosen by the platform factory
  /// beside [installDir], which is where the guest/host fact lives.
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

  /// Copies the base rootfs from cache into the project's data directory, for
  /// a project that opted into rootfs isolation. A no-op where no rootfs is
  /// selected (the desktop case); an error string where it cannot. [install]
  /// calls this first.
  Future<String?> ensureRootfs();

  /// Writes the `.setup-complete` marker, the one `setupCompleteProvider`
  /// reads to lift the chat page's gate. [install] calls this on success.
  Future<void> markSetupComplete();

  /// Runs the bundled install script through [shell]'s configured terminal
  /// env: [ensureRootfs] first, then the script — which puts `make`,
  /// `github-cli` and ESBMC where [installDir] names — then the marker. The
  /// script answers to what it is told, never to what it can probe, and a
  /// user-set ENV_INSTALL_DIR in settings cannot override the store (command
  /// environment wins over the app's own; see `composeEnvironment`).
  Future<ShellResult> install(Shell shell) async {
    final err = await ensureRootfs();
    if (err != null) return ShellResult.failed(err);
    final body = await rootBundle.loadString("assets/scripts/byte-repair-setup.sh");
    final result = await _run(shell, body, installTimeout,
        // Null installDir is the "no host install" answer — the setup's own
        // refusal to guess a destination is what the model then reads.
        environment: installEnvironment());
    if (result.returnCode == 0) await markSetupComplete();
    return result;
  }

  /// The environment the install run carries, layered over its driver's. The
  /// base is the destination, as `ENV_INSTALL_DIR`; the concrete store can
  /// add what its side of the platform owns — the binary's name, where the
  /// gate asking for the file it names lives beside the const that answers.
  Map<String, String> installEnvironment() =>
      {"ENV_INSTALL_DIR": installDir ?? ""};

  /// Copies a user-picked ESBMC binary next to the tools the setup fetched,
  /// making it executable. The rootfs must already exist — run [install]
  /// first. Null on success, an error message on failure.
  Future<String?> importEsbmc(XFile file);

  /// Deletes the Byte Repair environment: the per-project rootfs (the Alpine
  /// copy and everything installed into it) on Android, the fetched tools'
  /// cache directory on every desktop, the workspace (cloned repos, scratch
  /// files), and the `.setup-complete` marker. Chats are the settings page's
  /// to delete, through the repository. Null on success, an error message on
  /// failure.
  Future<String?> deleteEnvironment();

  /// One line naming what [deleteEnvironment] clears of the environment, for
  /// the settings page's confirm dialog: the setup's own tree, whatever state
  /// it left behind. null where nothing setup made is on disk — the dialog
  /// then names the workspace and the chats alone, which is what a platform
  /// with no install destination (iOS, the web) has, and a desktop that has
  /// not run a setup yet is the same by the state, not the platform. Reading
  /// the disk is the state: a Host env on Android copies nothing either.
  String? get environmentDeletion;

  /// What the settings page draws where this store's environment cannot run
  /// a setup — the env capability the section hides its buttons behind — or
  /// null where the buttons can run: a guest with a package manager on
  /// Android, an install destination on the desktops. The web's unavailable
  /// store is never capable. Answering here keeps the platform's own facts
  /// with what reads them (`defaultTargetPlatform`'s idea of a browser is
  /// the phone it runs on, which is why the widget must not ask).
  String? get capabilityBanner;

  /// The delete confirm's message, composed from the two facts this class
  /// holds: the [environmentDeletion] clause the setup left, and — through
  /// [capabilityBanner] — whether a setup can stand where it was again.
  /// Built here rather than wired through the widget's bits, the way the
  /// stores' `_why` answers already reach their readers.
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

  /// Runs `<command> --version` through [shell] and returns its raw output, or
  /// null where the command is not installed or the call failed. All three tools
  /// are on PATH inside the guest rootfs, so bare command names work.
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

  /// Checks all three tools the setup installs — ESBMC, make and gh — and
  /// returns a map of tool name to its version string (or null where not
  /// installed). All three are on PATH inside the per-project rootfs, or in
  /// the injected bin directory on the host.
  Future<Map<String, String?>> runToolVersions(Shell shell) async {
    final entries = await Future.wait(
      tools.entries.map((e) async => MapEntry(e.key, await runToolVersion(shell, e.value))),
    );
    return Map.fromEntries(entries);
  }
}

const _guestInstallTimeout = Duration(minutes: 10);

/// Where a guest's install script lands its tools: the rootfs's own
/// `/usr/local/bin`, now declared rather than implied. The host's answer is
/// composed per platform beside the cache directory.
const guestEsbmcInstallDir = "/usr/local/bin";

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
  String? get capabilityBanner =>
      "Byte Repair does not work on this platform: there is nowhere to "
      "install the tools it sets up.";
}