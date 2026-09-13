// Where prompt files come from: the presets embedded in code, and the user's
// own directory beside them.
import "package:fs_shim/fs.dart";

import "../../core/config.dart";
import "../../core/log.dart";
import "../../domain/bundled_prompt_file.dart";
import "../../domain/models.dart";
import "../../domain/project.dart" show defaultProjectDir;
import "../../domain/prompt_library.dart";
import "bundled_skill_data.dart";
import "skill_validate.dart";

/// The presets, embedded in code at build time by `tool/gen_bundled_skills.dart`.
/// The app is the source of truth for bundled skills and agents: the library
/// reads from the const list, not from the disk or the asset bundle. The disk
/// copy under `skills-bundled/` is a self-healed cache for bash access, written
/// by `installBundledSkills` at startup — the library never reads it.
///
/// Each entry is tagged with the project it belongs to. The default project's
/// entries are the base set every project inherits; another project's entries
/// override a same-named default one for that project alone. [project] selects
/// which project's overrides are layered on top of the default set, and `null`
/// (or `"default"`) is the default project alone. See "Skills and agents" in
/// `lib/domain/CLAUDE.md`.
class BundledPrompts implements PromptSource {
  const BundledPrompts({this.config, this.project});

  /// Whose filesystem the bundled skills' base directories are written to.
  /// Null loads no skills: a test exercising the agent half alone.
  final AppConfig? config;

  /// The project whose overrides are layered on top of the default set. Null
  /// is the default project, the way it is everywhere else a project is named.
  final String? project;

  @override
  Future<List<PromptDocument>> load(CompletionKind kind) async {
    switch (kind) {
      case CompletionKind.skill:
        final config = this.config;
        if (config == null) return const [];
        return _loadBundledSkills(config);
      case CompletionKind.agent:
        return _loadBundledAgents();
    }
  }

  List<PromptDocument> _loadBundledAgents() {
    final project = this.project ?? defaultProjectDir;
    final documents = <PromptDocument>[];
    // Default's first: the base set. A project's entries follow, so a
    // same-named override replaces the default one for that project.
    for (final file in bundledAgentFiles) {
      if (file.project != defaultProjectDir) continue;
      documents.add(
          PromptDocument.parse(CompletionKind.agent, file.name, file.content));
    }
    if (project != defaultProjectDir) {
      for (final file in bundledAgentFiles) {
        if (file.project != project) continue;
        documents.add(
            PromptDocument.parse(CompletionKind.agent, file.name, file.content));
      }
    }
    return documents;
  }

  /// Builds [PromptDocument]s from the embedded skill data, grouping files by
  /// skill name and prepending the base directory the same way
  /// [loadSkillDirectories] does for user skills. Only the `SKILL.md` entry is
  /// parsed — the other files (scripts, references) are for bash to reach by
  /// path, not for the library.
  ///
  /// The base directory is the one the skill's files live under on disk:
  /// the default project's `skills-bundled/` for a default entry, or the
  /// project's own for an override. The self-heal writes each to its own dir.
  List<PromptDocument> _loadBundledSkills(AppConfig config) {
    final project = this.project ?? defaultProjectDir;
    final documents = <PromptDocument>[];
    void emitFor(String tag) {
      final bySkill = <String, List<BundledPromptFile>>{};
      for (final file in bundledSkillFiles) {
        if (file.project != tag) continue;
        bySkill.putIfAbsent(file.name, () => []).add(file);
      }
      final baseDir = tag == defaultProjectDir
          ? config.bundledSkillsDir()
          : config.bundledSkillsDir(project: tag);
      for (final entry in bySkill.entries) {
        final skillName = entry.key;
        final skillMd = entry.value.firstWhere(
          (f) => f.relativePath == "SKILL.md",
          orElse: () => entry.value.first,
        );
        try {
          final document = _skillDocument(
            skillName,
            skillMd.content,
            config.fs.path.join(baseDir, skillName),
          );
          final problems = skillProblems(
            name: document.frontmatter["name"] ?? skillName,
            description: document.description,
            frontmatter: document.frontmatter,
            folderName: skillName,
          );
          if (problems.isNotEmpty) {
            logFailure("skills",
                "bundled skill $skillName skipped: ${problems.join("; ")}");
            continue;
          }
          documents.add(document);
        } catch (e) {
          logFailure("skills", "could not parse bundled skill $skillName: $e");
        }
      }
    }

    emitFor(defaultProjectDir);
    if (project != defaultProjectDir) emitFor(project);
    return documents;
  }
}

/// Whatever the user has put in a project's `skills/` and `agents/`
/// directories. The default project's entries are the base set every other
/// project inherits; [project]'s own entries are layered on top, replacing a
/// same-named default entry for that project alone. Over the config's
/// filesystem, so a browser has the directories too — the prompts a user
/// writes there are theirs on every platform.
class DirectoryPrompts implements PromptSource {
  const DirectoryPrompts(this.config, {this.project});

  final AppConfig config;

  /// The project whose overrides are layered on top of the default set. Null
  /// is the default project, the way it is everywhere else a project is named.
  final String? project;

  @override
  Future<List<PromptDocument>> load(CompletionKind kind) async {
    final documents = <PromptDocument>[];
    // Default's first, then the project's overrides. A project entry with the
    // same name as a default one replaces it for that project — the library's
    // "later replaces earlier" rule, the same one that lets a user's file
    // override a bundled preset.
    final defaultProject = await _loadKind(kind, defaultProjectDir);
    documents.addAll(defaultProject);
    final p = project;
    if (p != null && p != defaultProjectDir) {
      documents.addAll(await _loadKind(kind, p));
    }
    return documents;
  }

  Future<List<PromptDocument>> _loadKind(CompletionKind kind, String project) async {
    if (kind == CompletionKind.skill) {
      return loadSkillDirectories(config.fs, config.promptsDir(kind, project: project));
    }
    return _loadFlat(kind, project);
  }

  Future<List<PromptDocument>> _loadFlat(CompletionKind kind, String project) async {
    final path = config.fs.path;
    final directory = config.fs.directory(config.promptsDir(kind, project: project));
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
/// base directory is, and the spec requires the two to match, which
/// [skillProblems] checks.
///
/// The body carries the base directory above the template, because that is
/// the one thing every reader needs and none of them can work out: the
/// composer's expansion, the `skill` tool, and a replayed log all read the
/// same string. A folder whose `SKILL.md` cannot be read, or whose frontmatter
/// does not conform, is skipped with a line in the log — one broken skill
/// does not take the menu with it, and the skills settings page shows the
/// reason on the skill's view page.
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
      final document =
          _skillDocument(folderName, await file.readAsString(), entity.path);
      final problems = skillProblems(
        name: document.frontmatter["name"] ?? folderName,
        description: document.description,
        frontmatter: document.frontmatter,
        folderName: folderName,
      );
      if (problems.isNotEmpty) {
        logFailure("skills", "$folderName skipped: ${problems.join("; ")}");
        continue;
      }
      documents.add(document);
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
    metadata: parsed.metadata,
    body: _withBaseDir(baseDir, parsed.body),
  );
}

/// The skill as the model is given it: where its files are, then the
/// template. The directory is absolute on a disk and a path in the virtual
/// filesystem on the web, which is the same thing to the reader that matters.
String _withBaseDir(String baseDir, String body) =>
    "Base directory for this skill: $baseDir\n\n$body";