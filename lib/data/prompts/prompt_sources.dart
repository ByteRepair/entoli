// Where prompt files come from: the presets packaged with the app, and the
// user's own directory beside them.
import "dart:io";

import "package:flutter/services.dart";
import "package:path/path.dart" as p;

import "../../core/config.dart";
import "../../domain/models.dart";
import "../../domain/prompt_library.dart";

/// The presets, packaged at build time under `assets/prompts/`.
class BundledPrompts implements PromptSource {
  const BundledPrompts({this.bundle});

  /// Null means [rootBundle] — resolved on use, because a test binding swaps
  /// it out after this has been constructed.
  final AssetBundle? bundle;

  static String directoryFor(CompletionKind kind) => "assets/prompts/${kind.folder}/";

  @override
  Future<List<PromptDocument>> load(CompletionKind kind) async {
    final assets = bundle ?? rootBundle;
    final manifest = await AssetManifest.loadFromAssetBundle(assets);
    final directory = directoryFor(kind);
    final documents = <PromptDocument>[];
    for (final key in manifest.listAssets()) {
      if (!key.startsWith(directory) || !key.endsWith(".md")) continue;
      documents.add(PromptDocument.parse(
        kind,
        p.basenameWithoutExtension(key),
        await assets.loadString(key),
      ));
    }
    return documents;
  }
}

/// Whatever the user has put in `$AGENT_CHAT_CONFIG/{commands,agents}/`.
class DirectoryPrompts implements PromptSource {
  const DirectoryPrompts(this.config);

  final AppConfig config;

  @override
  Future<List<PromptDocument>> load(CompletionKind kind) async {
    final directory = config.promptsDir(kind);
    if (!directory.existsSync()) return const [];
    final documents = <PromptDocument>[];
    for (final entity in directory.listSync()) {
      if (entity is! File || p.extension(entity.path) != ".md") continue;
      documents.add(PromptDocument.parse(
        kind,
        p.basenameWithoutExtension(entity.path),
        entity.readAsStringSync(),
      ));
    }
    return documents;
  }
}
