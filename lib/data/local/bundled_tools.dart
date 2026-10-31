import "dart:io";

import "package:flutter/services.dart";
import "package:path/path.dart" as p;

import "../../domain/shell.dart";

/// The tools Entoli ships for Android, where the system has a shell but almost
/// nothing to run in it. Today that is proot, and so a whole Linux rather than
/// any one command. See "Bundled tools" in AGENTS.md for why they live where
/// they do and what that costs.
class BundledTools {
  const BundledTools._();

  static const _channel = MethodChannel("agent_chat/tools");

  /// Where the extracted `lib*.so` files are, or null where nothing answers
  /// the channel — every platform but Android.
  ///
  /// Asked once and kept: it is `applicationInfo.nativeLibraryDir`, constant
  /// for the life of the install, and two things now want it — the tools laid
  /// out below and the model server beside them. Holding the future rather than
  /// the answer means the second caller waits on the first round trip instead
  /// of starting a second.
  static Future<String?>? _libDir;

  static Future<String?> nativeLibraryDir() =>
      _libDir ??= _ask("nativeLibraryDir");

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

  /// The RAM this device has, in bytes. Null where nothing answers.
  static Future<int?> totalMemory() => _ask("totalMemory");

  static Future<T?> _ask<T>(String method) async {
    try {
      return await _channel.invokeMethod<T>(method);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Lay the tools out under [root] and answer with the environment that finds
  /// them. Null where this build ships nothing for the device's ABI, which
  /// leaves the shell exactly as it was.
  static Future<Toolset?> install({
    required String root,
    required String libDir,
  }) async {
    final tmp = Directory(p.join(root, "tmp"));
    // proot is not a command the model runs, it is what a command can be run
    // *inside*, which is why a build carrying only it still answers with a
    // toolset rather than nothing.
    final proot = await _proot(libDir, root: root, tmp: tmp);
    if (proot == null) return null;
    return Toolset(environment: {"TMPDIR": tmp.path}, proot: proot);
  }

  /// proot and its loader, where this build ships them. Named where they lie
  /// rather than linked into a prefix: the library directory is the only place
  /// the loader may be exec'd from, so a link into app storage would be
  /// pointing at the one thing that is not allowed.
  static Future<Proot?> _proot(
    String libDir, {
    required String root,
    required Directory tmp,
  }) async {
    final binary = File(p.join(libDir, "libproot.so"));
    final loader = File(p.join(libDir, "libproot-loader.so"));
    if (!binary.existsSync() || !loader.existsSync()) return null;
    final loader32 = File(p.join(libDir, "libproot-loader32.so"));
    await tmp.create(recursive: true);
    return Proot(
      binary: binary.path,
      loader: loader.path,
      loader32: loader32.existsSync() ? loader32.path : null,
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
}
