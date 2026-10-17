import "dart:io";

import "package:file_selector/file_selector.dart";
import "package:flutter/foundation.dart"
    show TargetPlatform, defaultTargetPlatform;
import "package:path/path.dart" as p;

import "../../core/log.dart";
import "../../domain/app_settings.dart";
import "byte_repair_store.dart";
import "tree_ops.dart";

/// The name ESBMC lands under in a bin directory. The setup script installs
/// under it and the setup gate checks for it, so both agree by asking here.
final String esbmcFileName = Platform.isWindows ? "esbmc.exe" : "esbmc";

/// The io side of [ByteRepairStore]: the rootfs copy, the ESBMC import, the
/// environment delete, and the markers.
class FileByteRepairStore extends ByteRepairStore {
  FileByteRepairStore({
    required super.config,
    required super.project,
    required super.workspace,
    super.installDir,
    super.installTimeout,
    super.rootfsStore,
  });

  @override
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
    if (File(p.join(target, ".complete")).existsSync()) return null;
    final err = await copyTree(baseDir, target);
    if (err != null) {
      logFailure("byte-repair", "rootfs copy failed", err);
      return "Failed to copy rootfs: $err";
    }
    File(p.join(target, ".complete")).writeAsStringSync(id);
    return null;
  }

  @override
  Future<void> markSetupComplete() async {
    // Recursive: setup can run before any byte-repair chat has made the
    // project's directory.
    final marker = File(config.setupCompleteFile(project: project))
      ..createSync(recursive: true);
    marker.writeAsStringSync("done");
  }

  @override
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

  @override
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
      if (await marker.exists()) await marker.delete();
      return null;
    } catch (e) {
      logFailure("byte-repair", "delete environment failed", e);
      return e.toString();
    }
  }

  @override
  Map<String, String> installEnvironment() => {
        ...super.installEnvironment(),
        "ENV_ESBMC_BINARY": esbmcFileName,
      };

  @override
  String? get capabilityBanner {
    // On a guest platform the rootfs pick is the gate: a "Host" env has no
    // package manager on Android and no shell at all on iOS. The target, not
    // `Platform`, so the section's fixtures can name their platform.
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      if (AppSettings.load(config).rootfsId != null) return null;
      return defaultTargetPlatform == TargetPlatform.android
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

  @override
  String? get environmentDeletion {
    if (Directory(_rootfsTree).existsSync()) {
      return "the Byte Repair rootfs (the Linux copy and everything "
          "installed into it)";
    }
    if (_hostInstallDir != null && Directory(_hostInstallDir!).existsSync()) {
      return "the tools the setup fetched into the app's cache directory";
    }
    return null;
  }

  /// The host tree an install creates, or null where [installDir] is the
  /// guest's own `/usr/local/bin`, a path inside the Linux.
  String? get _hostInstallDir =>
      installDir == guestEsbmcInstallDir ? null : installDir;

  /// Every per-project rootfs copy.
  String get _rootfsTree => p.join(config.projectDir(project: project), "rootfs");

  /// `/usr/local/bin` inside the selected rootfs's project copy, or null
  /// where setup has not made the copy yet.
  String? get _guestEsbmcDir {
    final id = AppSettings.load(config).rootfsId;
    if (id == null) return null;
    final dir = config.projectRootfsDir(project: project, rootfsId: id);
    return File(p.join(dir, ".complete")).existsSync()
        ? p.join(dir, "usr", "local", "bin")
        : null;
  }
}