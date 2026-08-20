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
  static Future<String?> nativeLibraryDir() => _ask("nativeLibraryDir");

  /// The ABI this install is for — `arm64-v8a` and friends. Null off Android,
  /// where nothing is bundled for one.
  static Future<String?> abi() => _ask("abi");

  /// What the network this device is on resolves names with. Empty where
  /// nothing answers, or where Android says the device is on no network.
  static Future<List<String>> dnsServers() async {
    try {
      final answer = await _channel.invokeListMethod<String>("dnsServers");
      return answer ?? const [];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  static Future<String?> _ask(String method) async {
    try {
      return await _channel.invokeMethod<String>(method);
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
    final hasGit = await git.exists();
    final tmp = Directory(p.join(root, "tmp"));
    // proot on its own is still worth answering with: it is not a command the
    // model runs, it is what a command can be run *inside*.
    final proot = await _proot(libDir, root: root, tmp: tmp);
    if (!hasGit) {
      return proot == null
          ? null
          : Toolset(environment: {"TMPDIR": tmp.path}, proot: proot);
    }

    final bin = Directory(p.join(root, "bin"));
    final execPath = Directory(p.join(root, "libexec", "git-core"));
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
      proot: proot,
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

  /// proot and its loader, where this build ships them. Named where they lie
  /// rather than linked into [install]'s tree the way git is: the library
  /// directory is the only place the loader may be exec'd from, so a link into
  /// app storage would be pointing at the one thing that is not allowed.
  static Future<Proot?> _proot(
    String libDir, {
    required String root,
    required Directory tmp,
  }) async {
    final binary = File(p.join(libDir, "libproot.so"));
    final loader = File(p.join(libDir, "libproot-loader.so"));
    if (!await binary.exists() || !await loader.exists()) return null;
    final loader32 = File(p.join(libDir, "libproot-loader32.so"));
    await tmp.create(recursive: true);
    return Proot(
      binary: binary.path,
      loader: loader.path,
      loader32: await loader32.exists() ? loader32.path : null,
      tmpDir: tmp.path,
      resolvConf: await _writeResolvConf(root),
    );
  }

  /// The guest's `/etc/resolv.conf`, written from what Android says the network
  /// resolves with. Here rather than into the rootfs, and rewritten on every
  /// launch, because it is one file whatever is installed and because the answer
  /// changes with the network the device is on — a file written once at install
  /// would name the resolver of whatever WiFi the user was on that day.
  ///
  /// Nothing is written where Android says nothing: a guest with no resolver
  /// fails to look a name up, which is honest, where a public one picked here
  /// would send the user's queries somewhere they never chose.
  static Future<String> _writeResolvConf(String root) async {
    final file = File(p.join(root, "etc", "resolv.conf"));
    final servers = await dnsServers();
    await file.parent.create(recursive: true);
    await file.writeAsString(servers.map((s) => "nameserver $s\n").join());
    return file.path;
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
