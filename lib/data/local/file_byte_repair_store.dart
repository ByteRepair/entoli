import "dart:io";

import "package:file_selector/file_selector.dart";
import "package:path/path.dart" as p;

import "../../core/log.dart";
import "../../domain/app_settings.dart";
import "byte_repair_store.dart";
import "tree_ops.dart";

/// The io side of [ByteRepairStore]: the rootfs copy, the ESBMC import, the
/// environment delete, and the markers both read and written. `dart:io` for
/// the same reason `FileRootfsStore` is: this side of the conditional import
/// is the only one that can run what is in there.
class FileByteRepairStore extends ByteRepairStore {
  FileByteRepairStore({
    required super.config,
    required super.project,
    required super.workspace,
    super.rootfsStore,
  });

  @override
  Future<String?> ensureRootfs() async {
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

  @override
  Future<String?> deleteEnvironment() async {
    final err = await removeTree(p.join(config.projectDir(project: project), "rootfs"));
    if (err != null) {
      logFailure("byte-repair", "delete environment failed", err);
      return err;
    }
    final wsErr = await removeTree(config.projectWorkspaceDir(project: project));
    if (wsErr != null) {
      logFailure("byte-repair", "delete environment failed", wsErr);
      return wsErr;
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

  /// The per-project rootfs directory for the currently selected rootfs id, or
  /// null where the copy has not been created yet.
  String? get _rootfsDir {
    final id = AppSettings.load(config).rootfsId;
    if (id == null) return null;
    final dir = config.projectRootfsDir(project: project, rootfsId: id);
    return File(p.join(dir, ".complete")).existsSync() ? dir : null;
  }
}