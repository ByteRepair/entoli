import "dart:io";

import "package:file_selector/file_selector.dart";
import "package:flutter/foundation.dart"
    show TargetPlatform, defaultTargetPlatform;
import "package:path/path.dart" as p;

import "../../core/log.dart";
import "../../domain/app_settings.dart";
import "byte_repair_store.dart";
import "tree_ops.dart";

/// The name ESBMC lands under wherever this store keeps a bin directory:
/// `.exe` where Windows needs the extension for anything to exec it, bare
/// where POSIX names the file outright. The setup script installs under it
/// and the platform's setup gate checks for it, so both agree by asking here.
final String esbmcFileName = Platform.isWindows ? "esbmc.exe" : "esbmc";

/// The io side of [ByteRepairStore]: the rootfs copy, the ESBMC import, the
/// environment delete, and the markers both read and written. `dart:io` for
/// the same reason `FileRootfsStore` is: this side of the conditional import
/// is the only one that can run what is in there.
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
    // The per-project copy is the proot guest's filesystem. Where no guest
    // can run — every platform but Android — there is nothing to copy onto,
    // and a rootfsId left over from another device must not pay for a copy
    // nothing reads.
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
    final destDirPath = Platform.isAndroid ? _guestEsbmcDir : installDir;
    if (destDirPath == null) {
      return "The Byte Repair rootfs has not been set up yet. Run Setup first.";
    }
    try {
      final destDir = Directory(destDirPath);
      await destDir.create(recursive: true);
      final dest = p.join(destDir.path, esbmcFileName);
      await File(dest).writeAsBytes(await file.readAsBytes());
      // Windows reports no mode bits, so there is nothing for a chmod to do
      // — and no chmod to run.
      if (!Platform.isWindows) await Process.run("chmod", ["+x", dest]);
      return null;
    } catch (e) {
      logFailure("byte-repair", "import ESBMC failed", e);
      return e.toString();
    }
  }

  @override
  Future<String?> deleteEnvironment() async {
    // The rootfs and workspace trees are independent, so the two `chmod`+`rm`
    // runs go together — on a slow phone either alone is a long wait, and the
    // workspace has no dependency on the rootfs being gone.
    final errors = await Future.wait([
      removeTree(_rootfsTree),
      removeTree(config.projectWorkspaceDir(project: project)),
      // The host's fetched binaries; nothing on disk where there was
      // nothing to point at.
      if (!Platform.isAndroid && installDir != null)
        removeTree(p.dirname(installDir!)),
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
        // The binary's name is this side's answer — `.exe` where anything
        // Windows runs execs by extension, bare where POSIX names the file —
        // sent through the same "the script answers to what it is told" seam
        // the destination rides.
        "ENV_ESBMC_BINARY": esbmcFileName,
      };

  @override
  String? get capabilityBanner {
    // The env on offer: a "Host" env on Android has no package manager, a
    // guest's rootfs pick is where one comes from; a desktop's host shell is
    // capable where the platform composes a destination, and is told so
    // where there is none — iOS, and the web's unavailable store. The
    // target read, not `Platform.isAndroid`: the section's fixtures name
    // their platform the way the UI facts are named everywhere else.
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AppSettings.load(config).rootfsId == null
          ? 'Byte Repair does not work when using the "Host" terminal '
              "environment on this device. Please choose another terminal "
              "environment."
          : null;
    }
    return installDir == null
        ? "Byte Repair does not work on this platform: there is nowhere to "
            "install the tools it sets up."
        : null;
  }

  @override
  String? get environmentDeletion {
    // What the setup leaves on disk is what a delete takes away, so the
    // dialog words it from the disk rather than from the platform: a Host
    // env on Android made no copy, and a desktop that has not run a setup
    // fetched nothing — the clause drops out of the dialog, which then
    // names the workspace and the chats alone. The host install checks the
    // bin itself; the delete takes the cache directory around it, but the
    // bin is the one tree a run actually creates. The [!Platform.isAndroid]
    // guard is the delete's own: the value behind it on Android is the
    // guest's `/usr/local/bin`, never a host tree this getter could word —
    // the rootfs clause above answers whenever a guest is there at all.
    if (Directory(_rootfsTree).existsSync()) {
      return "the Byte Repair rootfs (the Linux copy and everything "
          "installed into it)";
    }
    if (!Platform.isAndroid &&
        installDir != null &&
        Directory(installDir!).existsSync()) {
      return "the tools the setup fetched into the app's cache directory";
    }
    return null;
  }

  /// The per-project rootfs copy the guest runs in — the tree the setup's
  /// copy makes, [deleteEnvironment] takes whole, and this getter words.
  String get _rootfsTree => p.join(config.projectDir(project: project), "rootfs");

  /// The per-project rootfs directory for the currently selected rootfs id, or
  /// null where the copy has not been created yet.
  String? get _rootfsDir {
    final id = AppSettings.load(config).rootfsId;
    if (id == null) return null;
    final dir = config.projectRootfsDir(project: project, rootfsId: id);
    return File(p.join(dir, ".complete")).existsSync() ? dir : null;
  }

  /// Where a guest keeps the tools the setup fetches — `/usr/local/bin` inside
  /// its own rootfs copy, reached only after setup has made the copy.
  String? get _guestEsbmcDir {
    final dir = _rootfsDir;
    return dir == null ? null : p.join(dir, "usr", "local", "bin");
  }
}