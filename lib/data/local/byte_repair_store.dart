import "dart:io";

import "package:flutter/services.dart" show rootBundle;
import "package:path/path.dart" as p;

import "../../domain/shell.dart";
import "../../core/log.dart";

/// Installs and queries the Byte Repair tooling — make, github-cli and ESBMC —
/// in `<cacheDir>/byte-repair/bin`. The install runs through the configured
/// terminal env (proot rootfs on Android, host shell on desktop), so the script
/// reaches the package manager the user's commands reach. `dart:io` for the
/// same reason `FileRootfsStore` is: this side of the conditional import is the
/// only one that can run what is in there.
class ByteRepairStore {
  ByteRepairStore(this.cacheDir) : binDir = p.join(cacheDir, "byte-repair", "bin");

  final String cacheDir;
  final String binDir;

  /// The path `esbmc` is installed to, or null where it is not there. A sync
  /// stat the way `FileRootfsStore.directoryOfSync` is one — the version read
  /// asks it before it asks the shell.
  String? get esbmcPath {
    final file = File(p.join(binDir, "esbmc"));
    return file.existsSync() ? file.path : null;
  }

  /// Runs the bundled install script through [shell]'s configured terminal env.
  /// Returns the shell's result; a `returnCode` of 0 is success.
  Future<ShellResult> install(Shell shell) async {
    await Directory(binDir).create(recursive: true);
    final scriptPath = p.join(binDir, "_setup.sh");
    final script = File(scriptPath);
    try {
      final body = await rootBundle.loadString("assets/scripts/byte-repair-setup.sh");
      await script.writeAsString(body);
      final run = shell.start(
        "sh \"$scriptPath\" \"$binDir\"",
        cwd: binDir,
        home: binDir,
        timeout: const Duration(minutes: 10),
        oneShot: true,
      );
      return await run.result;
    } catch (e) {
      logFailure("byte-repair", "setup script failed", e);
      return ShellResult.failed(e.toString());
    } finally {
      try {
        if (script.existsSync()) await script.delete();
      } catch (_) {
      }
    }
  }

  /// Runs `esbmc --version` through [shell] and returns its raw output, or null
  /// where esbmc is not installed or the call failed.
  Future<String?> runVersion(Shell shell) async {
    final esbmc = esbmcPath;
    if (esbmc == null) return null;
    try {
      final run = shell.start(
        "\"$esbmc\" --version",
        cwd: binDir,
        home: binDir,
        timeout: const Duration(seconds: 15),
        oneShot: true,
      );
      final result = await run.result;
      if (result.returnCode == 0) return result.output.trim();
      if (result.exceptionInfo != null) {
        logFailure("byte-repair", "esbmc --version failed", result.exceptionInfo);
      }
      return null;
    } catch (e) {
      logFailure("byte-repair", "esbmc --version threw", e);
      return null;
    }
  }
}