// Where prompt files come from: the presets packaged with the app, and the
// user's own directory beside them.
import "package:flutter/services.dart";
import "package:fs_shim/fs.dart";
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

/// Whatever the user has put in `$AGENT_CHAT_CONFIG/{commands,agents}/`. Over
/// the config's filesystem, so a browser has the directory too — the prompts a
/// user writes there are theirs on every platform.
class DirectoryPrompts implements PromptSource {
  const DirectoryPrompts(this.config);

  final AppConfig config;

  @override
  Future<List<PromptDocument>> load(CompletionKind kind) async {
    final path = config.fs.path;
    final directory = config.fs.directory(config.promptsDir(kind));
    if (!await directory.exists()) return const [];
    final documents = <PromptDocument>[];
    await for (final entity in directory.list()) {
      if (entity is! File || path.extension(entity.path) != ".md") continue;
      documents.add(PromptDocument.parse(
        kind,
        path.basenameWithoutExtension(entity.path),
        await entity.readAsString(),
      ));
    }
    return documents;
  }
}
