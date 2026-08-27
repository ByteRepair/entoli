// Where prompt files come from: the presets embedded in code, and the user's
// own directory beside them.
import "package:fs_shim/fs.dart";

import "../../core/config.dart";
import "../../core/log.dart";
import "../../domain/models.dart";
import "../../domain/prompt_library.dart";
import "bundled_skill_data.dart";

/// The presets, embedded in code at build time by `tool/gen_bundled_skills.dart`.
/// The app is the source of truth for bundled skills and agents: the library
/// reads from the const lists, not from the disk or the asset bundle. The disk
/// copy under `skills-bundled/` is a self-healed cache for bash access, written
/// by `installBundledSkills` at startup — the library never reads it.
class BundledPrompts implements PromptSource {
  const BundledPrompts({this.config});

  /// Whose filesystem the bundled skills' base directories are written to.
  /// Null loads no skills: a test exercising the agent half alone.
  final AppConfig? config;

  @override
  Future<List<PromptDocument>> load(CompletionKind kind) async {
    switch (kind) {
      case CompletionKind.skill:
        final config = this.config;
        if (config == null) return const [];
        return _loadBundledSkills(config);
      case CompletionKind.agent:
        return [
          for (final file in bundledAgentFiles)
            PromptDocument.parse(kind, file.name, file.content),
        ];
    }
  }

  /// Builds [PromptDocument]s from the embedded skill data, grouping files by
  /// skill name and prepending the base directory the same way
  /// [loadSkillDirectories] does for user skills. Only the `SKILL.md` entry is
  /// parsed — the other files (scripts, references) are for bash to reach by
  /// path, not for the library.
  List<PromptDocument> _loadBundledSkills(AppConfig config) {
    final bySkill = <String, List<BundledPromptFile>>{};
    for (final file in bundledSkillFiles) {
      bySkill.putIfAbsent(file.name, () => []).add(file);
    }
    final documents = <PromptDocument>[];
    for (final entry in bySkill.entries) {
      final skillName = entry.key;
      final skillMd = entry.value.firstWhere(
        (f) => f.relativePath == "SKILL.md",
        orElse: () => entry.value.first,
      );
      try {
        documents.add(_skillDocument(
          skillName,
          skillMd.content,
          config.fs.path.join(config.bundledSkillsDir, skillName),
        ));
      } catch (e) {
        logFailure("skills", "could not parse bundled skill $skillName: $e");
      }
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
      documents.add(_skillDocument(folderName, await file.readAsString(), entity.path));
    } catch (e) {
      logFailure("skills", "could not read $folderName: $e");
    }
  }
  return documents;
}

/// The one way a skill becomes a [PromptDocument], whether it was read from
/// disk or from the embedded const. The name is the frontmatter's where it has
/// one, the folder's otherwise, and the body carries the base directory above
/// the template — the one thing every reader needs and none can work out.
PromptDocument _skillDocument(String folderName, String skillMd, String baseDir) {
  final parsed = PromptDocument.parse(CompletionKind.skill, folderName, skillMd);
  return PromptDocument(
    kind: CompletionKind.skill,
    name: parsed.frontmatter["name"] ?? folderName,
    frontmatter: parsed.frontmatter,
    body: _withBaseDir(baseDir, parsed.body),
  );
}

/// The skill as the model is given it: where its files are, then the
/// template. The directory is absolute on a disk and a path in the virtual
/// filesystem on the web, which is the same thing to the reader that matters.
String _withBaseDir(String baseDir, String body) =>
    "Base directory for this skill: $baseDir\n\n$body";
