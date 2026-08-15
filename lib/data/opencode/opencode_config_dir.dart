// How agent-chat drives opencode's config directory.
//
// opencode discovers commands and agents by globbing `{command,commands}/**`
// and `{agent,agents}/**` under every config directory it knows, and its
// global one always comes from `XDG_CONFIG_HOME` (verified against opencode
// 1.18.18: `Global.Path.config`). `OPENCODE_CONFIG_DIR` only *adds* a
// directory, so it cannot isolate anything on its own.
//
// So the server runs with `XDG_CONFIG_HOME` pointed at agent-chat's cache
// directory, which makes opencode's config `<cache>/agent-chat/opencode`, and
// agent-chat writes its own library there. The user's `~/.config/opencode`
// stops applying. `XDG_DATA_HOME` is deliberately left alone: credentials and
// the session database live there and are the user's, not ours.
import "dart:io";

import "package:path/path.dart" as p;

import "../../core/config.dart";
import "../../domain/models.dart";
import "../../domain/prompt_library.dart";

/// The directory names opencode reads. Singular is what its documentation
/// uses; the plural forms it also accepts are agent-chat's own.
const _opencodeFolders = {
  CompletionKind.command: "command",
  CompletionKind.agent: "agent",
};

/// Replace whatever is in [directory] with [library]. Rewritten from scratch
/// on every start: a command the user deleted must stop being offered, and
/// nothing here is worth keeping.
void writeOpencodeConfig(PromptLibrary library, Directory directory) {
  for (final kind in CompletionKind.values) {
    final target = Directory(p.join(directory.path, _opencodeFolders[kind]!));
    if (target.existsSync()) target.deleteSync(recursive: true);
    target.createSync(recursive: true);
    for (final document in library.entries(kind)) {
      File(p.join(target.path, "${document.name}.md")).writeAsStringSync(document.source);
    }
  }
}

Directory opencodeConfigDir(AppConfig config) =>
    Directory(p.join(config.cacheDir.path, "opencode"));

/// The environment an `opencode serve` runs under. [extra] is the user's own
/// (API keys, and whatever else a provider needs); the isolation comes last so
/// a typo there cannot quietly hand the chat someone else's commands.
Map<String, String> opencodeEnvironment(
  AppConfig config, {
  Map<String, String> extra = const {},
}) =>
    {...extra, "XDG_CONFIG_HOME": config.cacheDir.path};
