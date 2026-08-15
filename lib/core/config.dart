import "dart:io";
import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

import "../domain/models.dart";

/// Resolves platform-specific paths for the agent-chat data directory and
/// provides helpers for constructing chat paths.
///
/// Layout:
///   `<dataDir>/settings.json`
///   `<dataDir>/commands/*.md`, `<dataDir>/agents/*.md`
///   `<dataDir>/chats/<chat-id>/`
///     state.json
///     conv.json
///     resources/
///     workspace/
///
/// [cacheDir] is what a backend may throw away and rebuild: nothing the user
/// typed lives there.
class AppConfig {
  AppConfig._(this.dataDir, this.cacheDir);

  /// Test-only constructor using an explicit data directory.
  @visibleForTesting
  AppConfig.forDirectory(this.dataDir, {Directory? cacheDir})
      : cacheDir = cacheDir ?? Directory(p.join(dataDir.path, "cache"));

  final Directory dataDir;
  final Directory cacheDir;

  static Future<AppConfig> load() async {
    final override = Platform.environment["AGENT_CHAT_CONFIG"];
    final config = AppConfig._(
      Directory(override ?? p.join(await _resolveBase(), "agent-chat")),
      Directory(p.join(await _resolveCacheBase(), "agent-chat")),
    );
    config.ensureDirs();
    return config;
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

  static Future<String> _resolveCacheBase() async {
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      return Platform.environment["XDG_CACHE_HOME"] ?? p.join(_home, ".cache");
    }
    final dir = await getApplicationCacheDirectory();
    return dir.path;
  }

  static String get _home =>
      Platform.environment["HOME"] ?? Platform.environment["USERPROFILE"]!;

  Directory get chatsDir => Directory(p.join(dataDir.path, "chats"));

  Directory chatDir(String chatId) => Directory(p.join(chatsDir.path, chatId));

  File stateFile(String chatId) => File(p.join(chatDir(chatId).path, "state.json"));

  File convFile(String chatId) => File(p.join(chatDir(chatId).path, "conv.json"));

  File metaFile(String chatId) => File(p.join(chatDir(chatId).path, "meta.json"));

  Directory resourcesDir(String chatId) => Directory(p.join(chatDir(chatId).path, "resources"));

  Directory workspaceDir(String chatId) => Directory(p.join(chatDir(chatId).path, "workspace"));

  /// Where the user's own commands and agents go, beside the presets the app
  /// ships with.
  Directory promptsDir(CompletionKind kind) => Directory(p.join(dataDir.path, kind.folder));

  /// Create a chat's directories. Reading a path no longer creates it, so the
  /// few places that need them on disk say so.
  void ensureChatDirs(String chatId) {
    for (final dir in [chatDir(chatId), resourcesDir(chatId), workspaceDir(chatId)]) {
      if (!dir.existsSync()) dir.createSync(recursive: true);
    }
  }

  /// The prompt directories are created empty rather than on demand: an
  /// absent one is a worse hint than an empty one about where a custom
  /// command goes.
  void ensureDirs() {
    for (final dir in [
      dataDir,
      chatsDir,
      cacheDir,
      for (final kind in CompletionKind.values) promptsDir(kind),
    ]) {
      if (!dir.existsSync()) dir.createSync(recursive: true);
    }
  }

  File get settingsFile => File(p.join(dataDir.path, "settings.json"));
}
