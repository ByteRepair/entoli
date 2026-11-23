import "dart:io";

/// Whole-tree operations a rootfs needs, shelled out rather than `dart:io`,
/// because a rootfs contains things proot leaves behind that Dart cannot even
/// list.
///
/// **proot's bind stubs.** Where a bind's guest path does not exist in the
/// rootfs, proot creates it as a mode-0000 placeholder — the `/opt/skills*`
/// paths and `/etc/resolv.conf` are what this app's binds produce
/// (`proot.dart`). In the guest they are invisible: the bind shadows the stub,
/// which exists only to be mounted over. On the host they are poison: a
/// mode-0000 directory cannot be listed, so a recursive delete over a rootfs
/// that hosted a session dies on one — which is why the delete is
/// [removeTree]'s.

/// Deletes [path] and everything under it. `chmod -R u+rwX` first — a
/// mode-0000 stub, or anything a guest `chmod`'d read-only (proot maps those
/// onto the real files), can be neither listed nor deleted without it, and
/// `u+rwX` only ever adds bits — then `rm -rf`. Falls back to Dart's own
/// delete on a platform with neither command. Null on success, an error
/// message on failure.
Future<String?> removeTree(String path) async {
  final dir = Directory(path);
  if (!dir.existsSync()) return null;
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

/// Android's `tar` is toybox's. The absolute path is the fallback for a
/// device whose `PATH` does not name it — the same two-step `LocalShell` takes
/// to find a shell. `FileRootfsStore` unpacks a rootfs through it: a rootfs
/// is symlinks, execute bits and the odd hard link, and as a non-root process
/// tar preserves what it can and warns about the rest rather than failing.
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
