import "package:file_selector/file_selector.dart";
import "package:flutter/services.dart" show rootBundle;

import "../../core/config.dart";
import "../../core/log.dart";
import "../../domain/rootfs_store.dart";
import "../../domain/shell.dart";

/// Installs and queries the Byte Repair tooling — make, github-cli and ESBMC —
/// into the per-project rootfs, so they are on PATH for every agent turn in the
/// project. The install runs through the configured terminal env (proot rootfs
/// on Android, host shell on desktop) with [project], so it reaches the
/// project's own rootfs instance and the package manager inside it.
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
    this.rootfsStore,
  });

  final AppConfig config;
  final String project;
  final String workspace;

  /// The base rootfs a copy is made from. Null on the web platform.
  final RootfsStore? rootfsStore;

  static const tools = {"ESBMC": "esbmc", "make": "make", "gh": "gh"};

  Future<ShellResult> _run(Shell shell, String script, Duration timeout) async {
    try {
      final run = shell.start(
        script,
        cwd: workspace,
        home: workspace,
        timeout: timeout,
        oneShot: true,
        project: project,
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
  /// `github-cli` and ESBMC on PATH inside the rootfs — then the marker.
  Future<ShellResult> install(Shell shell) async {
    final err = await ensureRootfs();
    if (err != null) return ShellResult.failed(err);
    final body = await rootBundle.loadString("assets/scripts/byte-repair-setup.sh");
    final result = await _run(shell, body, const Duration(minutes: 10));
    if (result.returnCode == 0) await markSetupComplete();
    return result;
  }

  /// Copies a user-picked ESBMC binary into the per-project rootfs at
  /// `/usr/local/bin/esbmc`, making it executable. The rootfs must already
  /// exist — run [install] first. Null on success, an error message on
  /// failure.
  Future<String?> importEsbmc(XFile file);

  /// Deletes the Byte Repair environment: the per-project rootfs (the Alpine
  /// copy and everything installed into it), the workspace (cloned repos,
  /// scratch files), and the `.setup-complete` marker. Chats are the settings
  /// page's to delete, through the repository. Null on success, an error
  /// message on failure.
  Future<String?> deleteEnvironment();

  /// Runs `<command> --version` through [shell] and returns its raw output, or
  /// null where the command is not installed or the call failed. All three tools
  /// are on PATH inside the guest rootfs, so bare command names work.
  Future<String?> runToolVersion(Shell shell, String command) async {
    final result = await _run(shell, "$command --version", const Duration(seconds: 15));
    if (result.returnCode == 0) return result.output.trim().split("\n").first;
    if (result.exceptionInfo != null) {
      logFailure("byte-repair", "$command --version failed", result.exceptionInfo);
    }
    return null;
  }

  /// Checks all three tools the setup installs — ESBMC, make and gh — and
  /// returns a map of tool name to its version string (or null where not
  /// installed). All three are on PATH inside the per-project rootfs.
  Future<Map<String, String?>> runToolVersions(Shell shell) async {
    final entries = await Future.wait(
      tools.entries.map((e) async => MapEntry(e.key, await runToolVersion(shell, e.value))),
    );
    return Map.fromEntries(entries);
  }
}

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
}