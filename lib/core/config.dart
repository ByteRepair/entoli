import "dart:io";
import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

/// Resolves platform-specific paths for the agent-chat data directory and
/// provides helpers for constructing chat paths.
///
/// Layout:
///   `<dataDir>/agent-chat/settings.json`
///   `<dataDir>/chats/<chat-id>/`
///     state.json
///     conv.json
///     resources/
///     workspace/
class AppConfig {
  AppConfig._(this.dataDir);

  /// Test-only constructor using an explicit data directory.
  @visibleForTesting
  AppConfig.forDirectory(this.dataDir);

  final Directory dataDir;

  static Future<AppConfig> load() async {
    final base = await _resolveBase();
    final dataDir = Directory(p.join(base, "agent-chat"));
    if (!dataDir.existsSync()) dataDir.createSync(recursive: true);
    final chats = Directory(p.join(dataDir.path, "chats"));
    if (!chats.existsSync()) chats.createSync(recursive: true);
    return AppConfig._(dataDir);
  }

  static Future<String> _resolveBase() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final dir = await getApplicationDocumentsDirectory();
      return dir.path;
    }
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      final home = Platform.environment["HOME"] ?? Platform.environment["USERPROFILE"]!;
      return p.join(home, ".config");
    }
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  Directory get chatsDir => Directory(p.join(dataDir.path, "chats"));

  Directory chatDir(String chatId) => Directory(p.join(chatsDir.path, chatId));

  File stateFile(String chatId) => File(p.join(chatDir(chatId).path, "state.json"));

  File convFile(String chatId) => File(p.join(chatDir(chatId).path, "conv.json"));

  File metaFile(String chatId) => File(p.join(chatDir(chatId).path, "meta.json"));

  Directory resourcesDir(String chatId) {
    final d = Directory(p.join(chatDir(chatId).path, "resources"));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Directory workspaceDir(String chatId) {
    final d = Directory(p.join(chatDir(chatId).path, "workspace"));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  File get settingsFile => File(p.join(dataDir.path, "settings.json"));
}