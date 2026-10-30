// Where prompt files come from: the presets embedded in code, and the user's
// own directory beside them.

import "dart:io";

import "package:path/path.dart" as p;

import "../../core/config.dart";
import "../../core/log.dart";
import "../../domain/bundled_prompt_file.dart";
import "../../domain/builtin_project.dart" show omadaBaseProject, omadaFor;
import "../../domain/models.dart";
import "../../domain/project.dart" show defaultProjectDir;
import "../../domain/project_settings.dart";
import "../../domain/prompt_library.dart";
import "bundled_skill_data.dart";
import "skill_validate.dart";

/// The tiers in walk order: the default set first, then My Team's where the
/// project runs Omada, then the project's own. The library's "later replaces
/// earlier" rule is what makes the order the precedence — a project's own
/// entry answers over a My Team one, a My Team one over a default one. The
/// Omada answer is the one rule [omadaFor] resolves; the rung rides it, so
/// every source walks the same shape, skills included — My Team ships none,
/// and the absence of tagged files is the whole of that.
List<String> promptTiers({
  required String? project,
  required AppConfig? config,
}) => tiersFor(
  project,
  omada: omadaFor(
    project,
    projectOmada: config == null
        ? false
        : ProjectSettings.load(config, project: project).omada,
  ),
);

/// Where [project]'s prompts are read from on disk, every tier's: the bundled
/// skills, the user's skills and the user's agents. Nothing but the app writes
/// them, so this is what launch locks read-only and what a command is kept
/// from, one list for both. [executable] is a skills directory's, whose
/// scripts run.
List<({String path, bool executable})> promptDirsOf(
  AppConfig config, {
  String? project,
}) => [
  for (final tier in promptTiers(project: project, config: config)) ...[
    (path: config.bundledSkillsDir(project: tier), executable: true),
    (
      path: config.promptsDir(CompletionKind.skill, project: tier),
      executable: true,
    ),
    (
      path: config.promptsDir(CompletionKind.agent, project: tier),
      executable: false,
    ),
  ],
];

List<String> tiersFor(String? project, {required bool omada}) => [
  defaultProjectDir,
  if (omada && omadaBaseProject != project) omadaBaseProject,
  if (project != null && project != defaultProjectDir) project,
];

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
/// `lib/domain/AGENTS.md`.
class BundledPrompts implements PromptSource {
  // Not const: the tiers resolve off the config at first use, and no caller
  // constructs one in a constant expression.
  BundledPrompts({this.config, this.project});

  /// Whose filesystem the bundled skills' base directories are written to.
  /// Null loads no skills: a test exercising the agent half alone.
  final AppConfig? config;

  /// The project whose overrides are layered on top of the default set. Null
  /// is the default project, the way it is everywhere else a project is named.
  final String? project;

  /// The tiers this source serves, resolved once per source.
  late final List<String> _tiers = promptTiers(
    project: project,
    config: config,
  );

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
    final documents = <PromptDocument>[];
    for (final tag in _tiers) {
      for (final file in bundledAgentFiles) {
        if (file.project != tag) continue;
        documents.add(
          PromptDocument.parse(CompletionKind.agent, file.name, file.content),
        );
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
  /// The base directory is the tier's own `skills-bundled/`, where the
  /// self-heal writes it.
  List<PromptDocument> _loadBundledSkills(AppConfig config) {
    final documents = <PromptDocument>[];
    void emitFor(String tag) {
      final bySkill = <String, List<BundledPromptFile>>{};
      for (final file in bundledSkillFiles) {
        if (file.project != tag) continue;
        bySkill.putIfAbsent(file.name, () => []).add(file);
      }
      final baseDir = config.bundledSkillsDir(project: tag);
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
            p.join(baseDir, skillName),
          );
          final problems = skillDocumentProblems(document, skillName);
          if (problems.isNotEmpty) {
            logFailure(
              "skills",
              "bundled skill $skillName skipped: ${problems.join("; ")}",
            );
            continue;
          }
          documents.add(document);
        } catch (e) {
          logFailure("skills", "could not parse bundled skill $skillName: $e");
        }
      }
    }

    for (final tag in _tiers) {
      emitFor(tag);
    }
    return documents;
  }
}

/// Whatever the user has put in a project's `skills/` and `agents/`
/// directories. The default project's entries are the base set every other
/// project inherits; [project]'s own entries are layered on top, replacing a
/// same-named default entry for that project alone.
class DirectoryPrompts implements PromptSource {
  // Not const, for the same reason [BundledPrompts] is not.
  DirectoryPrompts(this.config, {this.project});

  final AppConfig config;

  /// The project whose overrides are layered on top of the default set. Null
  /// is the default project, the way it is everywhere else a project is named.
  final String? project;

  /// The tiers this source serves, resolved once per source — see
  /// [BundledPrompts._tiers].
  late final List<String> _tiers = promptTiers(
    project: project,
    config: config,
  );

  @override
  Future<List<PromptDocument>> load(CompletionKind kind) async {
    final documents = <PromptDocument>[];
    for (final tier in _tiers) {
      documents.addAll(await _loadKind(kind, tier));
    }
    return documents;
  }

  Future<List<PromptDocument>> _loadKind(
    CompletionKind kind,
    String project,
  ) async {
    if (kind == CompletionKind.skill) {
      return loadSkillDirectories(config.promptsDir(kind, project: project));
    }
    return _loadFlat(kind, project);
  }

  Future<List<PromptDocument>> _loadFlat(
    CompletionKind kind,
    String project,
  ) async {
    final directory = Directory(config.promptsDir(kind, project: project));
    if (!directory.existsSync()) return const [];
    final documents = <PromptDocument>[];
    await for (final entity in directory.list()) {
      if (entity is! File || p.extension(entity.path) != ".md") continue;
      documents.add(
        PromptDocument.parse(
          kind,
          p.basenameWithoutExtension(entity.path),
          await entity.readAsString(),
        ),
      );
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
/// A folder whose `SKILL.md` cannot be read, or whose frontmatter does not
/// conform, is skipped with a line in the log — one broken skill does not take
/// the menu with it, and the skills settings page shows the reason.
Future<List<PromptDocument>> loadSkillDirectories(String directory) async {
  final root = Directory(directory);
  if (!root.existsSync()) return const [];
  final documents = <PromptDocument>[];
  await for (final entity in root.list()) {
    if (entity is! Directory) continue;
    final folderName = p.basename(entity.path);
    final file = File(p.join(entity.path, "SKILL.md"));
    try {
      if (!file.existsSync()) continue;
      final document = _skillDocument(
        folderName,
        await file.readAsString(),
        entity.path,
      );
      final problems = skillDocumentProblems(document, folderName);
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
/// the template — the one thing every reader (the composer's expansion, the
/// `skill` tool, a replayed log) needs and none can work out.
PromptDocument _skillDocument(
  String folderName,
  String skillMd,
  String baseDir,
) {
  final parsed = PromptDocument.parse(
    CompletionKind.skill,
    folderName,
    skillMd,
  );
  return PromptDocument(
    kind: CompletionKind.skill,
    name: parsed.frontmatter["name"] ?? folderName,
    frontmatter: parsed.frontmatter,
    metadata: parsed.metadata,
    body: "Base directory for this skill: $baseDir\n\n${parsed.body}",
  );
}
