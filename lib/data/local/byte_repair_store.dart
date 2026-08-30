import "package:flutter/services.dart" show rootBundle;

import "../../domain/shell.dart";
import "../../core/log.dart";

/// Installs and queries the Byte Repair tooling — make, github-cli and ESBMC —
/// into the per-project rootfs, so they are on PATH for every agent turn in the
/// project. The install runs through the configured terminal env (proot rootfs
/// on Android, host shell on desktop) with `project: "byte-repair"`, so it
/// reaches the project's own rootfs instance and the package manager inside it.
class ByteRepairStore {
  ByteRepairStore(this.workspace);

  /// The Byte Repair project's workspace, bound at `/root` inside the guest.
  /// Used as cwd and home for the install script and the version checks.
  final String workspace;

  /// Runs the bundled install script through [shell]'s configured terminal env.
  /// The script installs make, github-cli and ESBMC into the guest rootfs —
  /// `apk` puts make and gh on PATH, and ESBMC is extracted to
  /// `/usr/local/bin/esbmc`. Returns the shell's result; `returnCode` 0 is
  /// success.
  Future<ShellResult> install(Shell shell) async {
    try {
      final body = await rootBundle.loadString("assets/scripts/byte-repair-setup.sh");
      final run = shell.start(
        body,
        cwd: workspace,
        home: workspace,
        timeout: const Duration(minutes: 10),
        oneShot: true,
        project: "byte-repair",
      );
      return await run.result;
    } catch (e) {
      logFailure("byte-repair", "setup script failed", e);
      return ShellResult.failed(e.toString());
    }
  }

  /// Runs `<command> --version` through [shell] and returns its raw output, or
  /// null where the command is not installed or the call failed. All three tools
  /// are on PATH inside the guest rootfs, so bare command names work.
  Future<String?> runToolVersion(Shell shell, String command) async {
    try {
      final run = shell.start(
        "$command --version",
        cwd: workspace,
        home: workspace,
        timeout: const Duration(seconds: 15),
        oneShot: true,
        project: "byte-repair",
      );
      final result = await run.result;
      if (result.returnCode == 0) return result.output.trim().split("\n").first;
      if (result.exceptionInfo != null) {
        logFailure("byte-repair", "$command --version failed", result.exceptionInfo);
      }
      return null;
    } catch (e) {
      logFailure("byte-repair", "$command --version threw", e);
      return null;
    }
  }

  /// Checks all three tools the setup installs — ESBMC, make and gh — and
  /// returns a map of tool name to its version string (or null where not
  /// installed). All three are on PATH inside the per-project rootfs.
  Future<Map<String, String?>> runToolVersions(Shell shell) async {
    final results = await Future.wait([
      runToolVersion(shell, "esbmc"),
      runToolVersion(shell, "make"),
      runToolVersion(shell, "gh"),
    ]);
    return {
      "ESBMC": results[0],
      "make": results[1],
      "gh": results[2],
    };
  }
}