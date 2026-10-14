import "dart:io";

import "package:path/path.dart" as p;

/// Whole-tree operations a rootfs needs, shelled out rather than `dart:io`,
/// because a rootfs contains things proot leaves behind that Dart cannot even
/// list.
///
/// **proot's bind stubs.** Where a bind's guest path does not exist in the
/// rootfs, proot creates it as a mode-0000 placeholder — the four `/opt/skills*`
/// paths and `/etc/resolv.conf` are what this app's binds produce (`proot.dart`:
/// the default project's two skills dirs, a project's own two beside them, and
/// the resolver). In the guest they are invisible: the bind shadows the stub,
/// which exists only to be mounted over. On the host they are poison: a
/// mode-0000 directory cannot be listed, so a recursive delete over a rootfs
/// that hosted a session dies on one, and a copy that has to read one does too.
/// The backup walker hits the same wall, since a per-project `rootfs/` lives
/// under the data directory — `writeBackup` skips it and `restoreBackup` clears
/// it through `removeTree`. All three failures were live on a device before
/// this comment was written.

/// The bind-stub guest paths, as `--exclude` patterns in both the `./`-prefixed
/// form tar archives them under and the bare one, so whichever form the
/// platform's tar stores, one matches. The project's two are bound only on
/// commands of the project that has them, but the stub is written wherever its
/// project's command ran — the shared base rootfs included, which is what a
/// setup copies from — so every rootfs copy excludes the lot.
const _bindStubExcludes = [
  "--exclude=./opt/skills",
  "--exclude=opt/skills",
  "--exclude=./opt/skills-bundled",
  "--exclude=opt/skills-bundled",
  "--exclude=./opt/skills-project",
  "--exclude=opt/skills-project",
  "--exclude=./opt/skills-bundled-project",
  "--exclude=opt/skills-bundled-project",
  "--exclude=./etc/resolv.conf",
  "--exclude=etc/resolv.conf",
];

/// Deletes [path] and everything under it. `chmod -R u+rwX` first — a
/// mode-0000 stub, or anything a guest `chmod`'d read-only (proot maps those
/// onto the real files), can be neither listed nor deleted without it, and
/// `u+rwX` only ever adds bits — then `rm -rf`. Falls back to Dart's own
/// delete on a platform with neither command. Null on success, an error
/// message on failure.
Future<String?> removeTree(String path) async {
  final dir = Directory(path);
  if (!await dir.exists()) return null;
  try {
    await Process.run("chmod", ["-R", "u+rwX", path]);
  } catch (_) {}
  try {
    final rm = await Process.run("rm", ["-rf", path]);
    if (rm.exitCode != 0) return "${rm.stderr}".trim();
    return null;
  } on ProcessException {
    try {
      await dir.delete(recursive: true);
      return null;
    } catch (e) {
      return e.toString();
    }
  }
}

/// Copies the whole tree at [base] into [target], which is cleared first —
/// whatever an earlier attempt left behind is worse than starting again. The
/// system's `tar` does the copying, the same tool `FileRootfsStore` unpacks
/// with and for the same reasons: a rootfs is symlinks, execute bits and the
/// odd hard link, and as a non-root process tar preserves what it can and
/// warns about the rest rather than failing. The bind-stub paths are
/// excluded: nothing at them is reachable in the guest — the binds shadow
/// them — and a mode-0000 stub cannot be read to be copied anyway. Null on
/// success, an error message on failure.
Future<String?> copyTree(String base, String target) async {
  final err = await removeTree(target);
  if (err != null) return err;
  try {
    await Directory(target).create(recursive: true);
  } catch (e) {
    return e.toString();
  }
  final temp = await Directory.systemTemp.createTemp("agent_chat_copy_");
  try {
    final archive = p.join(temp.path, "tree.tar");
    final create =
        await runTar(["-cf", archive, ..._bindStubExcludes, "-C", base, "."]);
    if (create.exitCode != 0) return "${create.stderr}".trim();
    final extract = await runTar(["-xf", archive, "-C", target]);
    if (extract.exitCode != 0) return "${extract.stderr}".trim();
    return null;
  } finally {
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  }
}

/// Android's `tar` is toybox's. The absolute path is the fallback for a
/// device whose `PATH` does not name it — the same two-step `LocalShell` takes
/// to find a shell. Shared with `FileRootfsStore`, which unpacks a rootfs
/// through it for the same reasons `copyTree` does.
Future<ProcessResult> runTar(List<String> args) async {
  for (final t in const ["tar", "/system/bin/tar"]) {
    try {
      return await Process.run(t, args);
    } on ProcessException {
      continue;
    }
  }
  throw const ProcessException("tar", [], "This device has no tar.");
}