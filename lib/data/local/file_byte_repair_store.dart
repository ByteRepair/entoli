import "dart:io";

import "package:file_selector/file_selector.dart";
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
      removeTree(p.join(config.projectDir(project: project), "rootfs")),
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
  String? get environmentDeletion {
    // What the setup leaves on disk is what a delete takes away, so the
    // dialog words it from the disk rather than from the platform: a Host
    // env on Android made no copy, and a desktop that has not run a setup
    // fetched nothing — the clause drops out of the dialog, which then
    // names the workspace and the chats alone. The host install checks the
    // bin itself; the delete takes the cache directory around it, but the
    // bin is the one tree a run actually creates.
    final rootfs =
        Directory(p.join(config.projectDir(project: project), "rootfs"));
    if (rootfs.existsSync()) {
      return "the Byte Repair rootfs (the Linux copy and everything "
          "installed into it)";
    }
    if (installDir != null && Directory(installDir!).existsSync()) {
      return "the tools the setup fetched into the app's cache directory";
    }
    return null;
  }

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