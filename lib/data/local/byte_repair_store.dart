import "package:flutter/services.dart" show rootBundle;

import "../../domain/shell.dart";
import "../../core/log.dart";

/// Installs and queries the Byte Repair tooling — make, github-cli and ESBMC —
/// into the per-project rootfs, so they are on PATH for every agent turn in the
/// project. The install runs through the configured terminal env (proot rootfs
/// on Android, host shell on desktop) with [project], so it reaches the
/// project's own rootfs instance and the package manager inside it.
class ByteRepairStore {
  ByteRepairStore({required this.project, required this.workspace});

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
