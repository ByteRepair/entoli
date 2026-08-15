import "dart:io";

import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

import "../../domain/storage.dart";

/// The filesystem, on desktop and Android.
class DiskStorage extends Storage {
  const DiskStorage();

  /// `$AGENT_CHAT_CONFIG` if set, else `~/.config/agent-chat` on desktop and
  /// app-private storage on Android.
  @override
  Future<String> dataDir() async {
    final override = Platform.environment["AGENT_CHAT_CONFIG"];
    return override ?? p.join(await _resolveBase(), "agent-chat");
  }

  static Future<String> _resolveBase() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final dir = await getApplicationDocumentsDirectory();
      return dir.path;
    }
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      return p.join(_home, ".config");
    }
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  static String get _home =>
      Platform.environment["HOME"] ?? Platform.environment["USERPROFILE"]!;

  @override
  void ensureDir(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
  }

  @override
  String? read(String path) {
    final file = File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  /// Synchronous like the reads: these are small local files, and a caller that
  /// has returned from a save treats it as durable.
  @override
  void write(String path, String text) => File(path).writeAsStringSync(text);
}
