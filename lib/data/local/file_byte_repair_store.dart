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
    required super.installDir,
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
    // On the host the binary lands in the app's own bin directory, which
    // exists once setup has run; the rootfs path is a guest's, and is null
    // until setup has made the copy — which is the gate the message names.
    final destDirPath = Platform.isAndroid ? _guestEsbmcDir : installDir;
    if (destDirPath == null) {
      return "The Byte Repair rootfs has not been set up yet. Run Setup first.";
    }
    try {
      final destDir = Directory(destDirPath);
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
    // The rootfs and workspace trees are independent, so the two `chmod`+`rm`
    // runs go together — on a slow phone either alone is a long wait, and the
    // workspace has no dependency on the rootfs being gone.
    final errors = await Future.wait([
      removeTree(p.join(config.projectDir(project: project), "rootfs")),
      removeTree(config.projectWorkspaceDir(project: project)),
      // The host's fetched binaries. No proot stubs are possible in here, but
      // removeTree costs nothing over a plain delete and is the one delete
      // this app has.
      if (!Platform.isAndroid) removeTree(p.dirname(installDir)),
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