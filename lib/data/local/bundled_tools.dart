import "dart:io";

import "package:flutter/services.dart";
import "package:path/path.dart" as p;

import "../../domain/shell.dart";

/// The tools Entoli ships for Android, where the system has a shell but almost
/// nothing to run in it. Today that is git and the helper it shells out to for
/// https. See "Bundled tools" in CLAUDE.md for why they live where they do and
/// what that costs.
class BundledTools {
  const BundledTools._();

  static const _channel = MethodChannel("agent_chat/tools");

  /// Where the extracted `lib*.so` files are, or null where nothing answers
  /// the channel — every platform but Android.
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
  /// that finds them and the names to tell the model. Null where this build
  /// ships nothing for the device's ABI, which leaves the shell exactly as it
  /// was.
  static Future<Toolset?> install({
    required String root,
    required String libDir,
  }) async {
    final git = File(p.join(libDir, "libgit.so"));
    if (!await git.exists()) return null;

    final bin = Directory(p.join(root, "bin"));
    final execPath = Directory(p.join(root, "libexec", "git-core"));
    final tmp = Directory(p.join(root, "tmp"));
    await Future.wait([
      bin.create(recursive: true),
      execPath.create(recursive: true),
      tmp.create(recursive: true),
    ]);

    await _link(p.join(bin.path, "git"), git.path);
    // git looks its own helpers up by name under GIT_EXEC_PATH, and the https
    // one is the only helper we ship: without it a clone over https reports
    // that the protocol is not supported.
    final http = File(p.join(libDir, "libgit-remote-http.so"));
    if (await http.exists()) {
      await Future.wait([
        for (final scheme in const ["http", "https", "ftp", "ftps"])
          _link(p.join(execPath.path, "git-remote-$scheme"), http.path),
      ]);
    }

    return Toolset(
      names: "git",
      environment: {
        "PATH": "${bin.path}:${Platform.environment["PATH"] ?? "/system/bin"}",
        "GIT_EXEC_PATH": execPath.path,
        // Android keeps its trust store as a directory of hashed certificates,
        // which is the shape OpenSSL's SSL_CERT_DIR wants; there is no bundle
        // file to point SSL_CERT_FILE at.
        "SSL_CERT_DIR": "/system/etc/security/cacerts",
        "HOME": root,
        "TMPDIR": tmp.path,
      },
    );
  }

  /// Replaced rather than kept: the library directory's path changes on every
  /// app update, so a link from the install before this one points at nothing.
  static Future<void> _link(String from, String to) async {
    final link = Link(from);
    if (await link.exists()) {
      if (await link.target() == to) return;
      await link.delete();
    }
    await link.create(to);
  }
}
