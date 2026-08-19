import "dart:io";

import "package:flutter/services.dart";
import "package:path/path.dart" as p;

/// The tools Entoli ships for Android, where the system has a shell but almost
/// nothing to run in it. Today that is git and the helper it shells out to for
/// https.
///
/// **They live in the native library directory**, which is the one place an app
/// may execute a file from: since Android 10 SELinux denies an app targeting
/// API 29 or higher `exec` on anything under its own data directory. That is
/// also why they are named `lib*.so` — the installer only extracts files
/// matching that out of an APK, and `useLegacyPackaging` is what makes it
/// extract them at all rather than mapping them from inside the APK, where
/// there would be no file to run.
///
/// What that costs is a toolset frozen at build time: nothing downloaded can
/// ever be executed, so there is no package manager and cannot be one. See
/// "Bundled tools" in CLAUDE.md for the road that would change it.
class BundledTools {
  const BundledTools._();

  static const _channel = MethodChannel("agent_chat/tools");

  /// Where the extracted `lib*.so` files are, or null off Android and on a
  /// device whose ABI we ship nothing for.
  static Future<String?> nativeLibraryDir() async {
    try {
      return await _channel.invokeMethod<String>("nativeLibraryDir");
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Lay the tools out as a prefix under [root] and answer with the environment
  /// a command needs to find them. Null where there is nothing bundled, which
  /// leaves the shell exactly as it was.
  ///
  /// A tree of symlinks rather than copies: a copy would be a second 12 MB in
  /// app storage, and — being in app storage — one nothing may execute. The
  /// link is followed at exec time, so what the kernel sees is the file in the
  /// library directory.
  static Future<Map<String, String>?> install({
    required String root,
    required String libDir,
  }) async {
    final git = File(p.join(libDir, "libgit.so"));
    if (!await git.exists()) return null;

    final bin = Directory(p.join(root, "bin"));
    final execPath = Directory(p.join(root, "libexec", "git-core"));
    await bin.create(recursive: true);
    await execPath.create(recursive: true);
    await Directory(p.join(root, "tmp")).create(recursive: true);

    await _link(p.join(bin.path, "git"), git.path);
    // git looks its own helpers up by name under GIT_EXEC_PATH, and the https
    // one is the only helper we ship: without it a clone over https reports
    // that the protocol is not supported.
    final http = File(p.join(libDir, "libgit-remote-http.so"));
    if (await http.exists()) {
      for (final scheme in const ["http", "https", "ftp", "ftps"]) {
        await _link(p.join(execPath.path, "git-remote-$scheme"), http.path);
      }
    }

    return {
      "PATH": "${bin.path}:${Platform.environment["PATH"] ?? "/system/bin"}",
      "GIT_EXEC_PATH": execPath.path,
      // Android keeps its trust store as a directory of hashed certificates,
      // which is the shape OpenSSL's SSL_CERT_DIR wants; there is no bundle
      // file to point SSL_CERT_FILE at.
      "SSL_CERT_DIR": "/system/etc/security/cacerts",
      "HOME": root,
      "TMPDIR": p.join(root, "tmp"),
    };
  }

  /// Replaced rather than kept: the library directory's path changes on every
  /// app update, so a link from the install before this one points at nothing.
  static Future<void> _link(String from, String to) async {
    final link = Link(from);
    if (await link.exists()) {
      if (await link.target() == to) return;
      await link.delete();
    } else if (await File(from).exists()) {
      await File(from).delete();
    }
    await link.create(to);
  }
}
