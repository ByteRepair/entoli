import "dart:io";

import "package:file_selector/file_selector.dart";
import "package:flutter/services.dart" show rootBundle;
import "package:path/path.dart" as p;

import "../../core/config.dart";
import "../../core/log.dart";
import "../../domain/app_settings.dart";
import "../../domain/shell.dart";

/// Installs and queries the Byte Repair tooling — make, github-cli and ESBMC —
/// into the per-project rootfs, so they are on PATH for every agent turn in the
/// project. The install runs through the configured terminal env (proot rootfs
/// on Android, host shell on desktop) with [project], so it reaches the
/// project's own rootfs instance and the package manager inside it.
class ByteRepairStore {
  ByteRepairStore({
    required this.config,
    required this.project,
    required this.workspace,
  });

  final AppConfig config;
  final String project;
  final String workspace;

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

  /// Runs the bundled install script through [shell]'s configured terminal env.
  /// The script installs make, github-cli and ESBMC into the guest rootfs —
  /// `apk` puts make and gh on PATH, and ESBMC is extracted to
  /// `/usr/local/bin/esbmc`. Returns the shell's result; `returnCode` 0 is
  /// success.
  Future<ShellResult> install(Shell shell) async {
    final body = await rootBundle.loadString("assets/scripts/byte-repair-setup.sh");
    return _run(shell, body, const Duration(minutes: 10));
  }

  /// Copies a user-picked ESBMC binary into the per-project rootfs at
  /// `/usr/local/bin/esbmc`, making it executable. The rootfs must already
  /// exist — run [install] first. Returns null on success, or an error
  /// message.
  Future<String?> importEsbmc(XFile file) async {
    final rootfsDir = _rootfsDir;
    if (rootfsDir == null) {
      return "The Byte Repair rootfs has not been set up yet. Run Setup first.";
    }
    try {
      final destDir = Directory(p.join(rootfsDir, "usr", "local", "bin"));
      await destDir.create(recursive: true);
      final dest = p.join(destDir.path, "esbmc");
      await File(dest).writeAsBytes(await file.readAsBytes());
      await Process.run("chmod", ["+x", dest]);
      return null;
    } catch (e) {
      logFailure("byte-repair", "import ESBMC failed", e);
      return e.toString();
    }
  }

  /// Deletes the Byte Repair environment: the per-project rootfs (the Alpine
  /// copy and everything installed into it) and the workspace (cloned repos,
  /// scratch files). Chats are not touched. The rootfs is re-created from the
  /// cache template on the next turn; the workspace on the next file write.
  Future<String?> deleteEnvironment() async {
    try {
      final rootfsRoot = p.join(config.projectDir(project: project), "rootfs");
      final dir = Directory(rootfsRoot);
      if (await dir.exists()) await dir.delete(recursive: true);
      final ws = Directory(config.projectWorkspaceDir(project: project));
      if (await ws.exists()) await ws.delete(recursive: true);
      return null;
    } catch (e) {
      logFailure("byte-repair", "delete environment failed", e);
      return e.toString();
    }
  }

  /// The per-project rootfs directory for the currently selected rootfs id, or
  /// null where the copy has not been created yet.
  String? get _rootfsDir {
    final id = AppSettings.load(config).rootfsId;
    if (id == null) return null;
    final dir = config.projectRootfsDir(project: project, rootfsId: id);
    return File(p.join(dir, ".complete")).existsSync() ? dir : null;
  }

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