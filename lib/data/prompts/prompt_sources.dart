// Where prompt files come from: the presets packaged with the app, and the
// user's own directory beside them.
import "package:flutter/services.dart";
import "package:fs_shim/fs.dart";
import "package:path/path.dart" as p;

import "../../core/config.dart";
import "../../core/log.dart";
import "../../domain/models.dart";
import "../../domain/prompt_library.dart";

/// The presets, packaged at build time under `assets/prompts/`. Agents are
/// single `.md` files read straight off the bundle; skills are directories,
/// and a skill's scripts and reference files need a real base directory
/// rather than an asset key — so they are extracted to the config's
/// filesystem at startup (see `bundled_skills.dart`) and read back from
/// there by [loadSkillDirectories].
class BundledPrompts implements PromptSource {
  const BundledPrompts({this.bundle, this.config});

  /// Null means [rootBundle] — resolved on use, because a test binding swaps
  /// it out after this has been constructed.
  final AssetBundle? bundle;

  /// Whose filesystem the extracted skills are read back off. Null loads no
  /// skills: a test exercising the agent half alone.
  final AppConfig? config;

  static String directoryFor(CompletionKind kind) => "assets/prompts/${kind.folder}/";

  @override
  Future<List<PromptDocument>> load(CompletionKind kind) async {
    if (kind == CompletionKind.skill) {
      final config = this.config;
      if (config == null) return const [];
      return loadSkillDirectories(config.fs, config.bundledSkillsDir);
    }
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

/// Whatever the user has put in `$AGENT_CHAT_CONFIG/{skills,agents}/`. Over
/// the config's filesystem, so a browser has the directory too — the prompts a
/// user writes there are theirs on every platform.
class DirectoryPrompts implements PromptSource {
  const DirectoryPrompts(this.config);

  final AppConfig config;

  @override
  Future<List<PromptDocument>> load(CompletionKind kind) {
    if (kind == CompletionKind.skill) {
      return loadSkillDirectories(config.fs, config.promptsDir(kind));
    }
    return _loadFlat(kind);
  }

  Future<List<PromptDocument>> _loadFlat(CompletionKind kind) async {
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

/// The skills under [directory]: one folder holding a `SKILL.md` each. The
/// document's name is the frontmatter's `name` where it has one, the folder's
/// name otherwise — the folder is what a `.skill` zip unpacks to and what the
/// base directory is, so the two names diverging is normal.
///
/// The body carries the base directory above the template, because that is
/// the one thing every reader needs and none of them can work out: the
/// composer's expansion, the `skill` tool, and a replayed log all read the
/// same string. A folder whose `SKILL.md` cannot be read is skipped with a
/// line in the log — one broken skill does not take the menu with it.
Future<List<PromptDocument>> loadSkillDirectories(FileSystem fs, String directory) async {
  final path = fs.path;
  final root = fs.directory(directory);
  if (!await root.exists()) return const [];
  final documents = <PromptDocument>[];
  await for (final entity in root.list()) {
    if (entity is! Directory) continue;
    final folderName = path.basename(entity.path);
    final file = fs.file(path.join(entity.path, "SKILL.md"));
    try {
      if (!await file.exists()) continue;
      final parsed =
          PromptDocument.parse(CompletionKind.skill, folderName, await file.readAsString());
      documents.add(PromptDocument(
        kind: CompletionKind.skill,
        name: parsed.frontmatter["name"] ?? folderName,
        frontmatter: parsed.frontmatter,
        body: _withBaseDir(entity.path, parsed.body),
      ));
    } catch (e) {
      logFailure("skills", "could not read $folderName: $e");
    }
  }
  return documents;
}

/// The skill as the model is given it: where its files are, then the
/// template. The directory is absolute on a disk and a path in the virtual
/// filesystem on the web, which is the same thing to the reader that matters.
String _withBaseDir(String baseDir, String body) =>
    "Base directory for this skill: $baseDir\n\n$body";
