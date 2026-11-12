import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:path/path.dart" as p;

import "../../core/config.dart";
import "../../core/formatting.dart" show formatSize;
import "../../core/platform/platform.dart" as platform;
import "../../data/prompts/prompt_export.dart" show skillSourceEntries;
import "../../data/prompts/skill_import.dart";
import "../../data/prompts/skill_validate.dart";
import "../../domain/frontmatter.dart";
import "../../domain/models.dart";

/// A project's own skills on disk: what each folder is wrong about, and
/// every write a page makes to them, each through the directory's lock. One
/// copy for every frontend's skills page.
class SkillFiles {
  const SkillFiles(this.config, {this.project});

  final AppConfig config;

  /// Null is the default project.
  final String? project;

  String _dir(String? project) =>
      config.promptsDir(CompletionKind.skill, project: project);

  /// Each folder in this project's own directory, and what it is wrong about:
  /// the rules the loader skips on, so a skipped skill is a row of its own.
  Future<Map<String, List<String>>> own() async {
    final dir = Directory(_dir(project));
    if (!dir.existsSync()) return const {};
    final folders = [
      await for (final entity in dir.list())
        if (entity is Directory) (p.basename(entity.path), entity.path),
    ];
    // The reads are independent, so they go out together.
    final answers = await Future.wait([
      for (final (name, path) in folders) _problems(path, name),
    ]);
    return {for (final (i, (name, _)) in folders.indexed) name: answers[i]};
  }

  /// A folder with no SKILL.md in it is a problem of its own; the loader
  /// skips it silently, this makes it a row.
  Future<List<String>> _problems(String path, String folderName) async {
    final file = File(p.join(path, "SKILL.md"));
    if (!file.existsSync()) return ["no SKILL.md in it"];
    try {
      return skillFrontmatterProblems(
        Frontmatter.parse(await file.readAsString()),
        folderName,
      );
    } catch (e) {
      return ["SKILL.md could not be read: $e"];
    }
  }

  /// Whether [name] is already installed in [target].
  bool has(String name, {String? target}) =>
      Directory(skillDirectory(config, name, project: target)).existsSync();

  Future<void> install(SkillPackage package, {String? target}) => platform
      .readOnlyDirs
      .skills(_dir(target))
      .write(() => installSkillPackage(config, package, project: target));

  Future<void> delete(String name) =>
      platform.readOnlyDirs.skills(_dir(project)).write(() async {
        await Directory(
          skillDirectory(config, name, project: project),
        ).delete(recursive: true);
      });
}

/// What a skill's page says where its files could not be read.
const skillUnreadable =
    "The skill's files could not be read. It may have been removed.";

/// [detail] of [name] as one page of Markdown, where a frontend shows it as
/// text: what it is for, what its folder is wrong about, its instructions,
/// and its other files.
String skillMarkdown(String name, SkillDetail? detail) {
  if (detail == null) return skillUnreadable;
  final md = detail.skillMd;
  return [
    "# $name",
    ?md?.description,
    if (detail.problems.isNotEmpty)
      "**Not loaded:** ${detail.problems.join("; ")}",
    ?md?.body,
    if (detail.files.isNotEmpty)
      "**Files**\n\n${[for (final (path, bytes) in detail.files) "- $path (${formatSize(bytes.length)})"].join("\n")}",
  ].join("\n\n");
}

/// A skill as its view page shows it: its SKILL.md read, what its
/// frontmatter is wrong about, and its other files.
typedef SkillDetail = ({
  Frontmatter? skillMd,
  List<String> problems,
  List<(String, Uint8List)> files,
});

/// [name]'s files as the library serves them — this project's own, a bundled
/// preset, or the default project's — or null where none could be read.
Future<SkillDetail?> skillDetail(
  AppConfig config,
  String name, {
  String? project,
}) async {
  final entries = await skillSourceEntries(config, name, project: project);
  if (entries == null) return null;
  final skillMd = entries.where((e) => e.$1 == "SKILL.md").firstOrNull;
  final parsed = skillMd == null
      ? null
      : Frontmatter.parse(utf8.decode(skillMd.$2));
  return (
    skillMd: parsed,
    problems: parsed == null
        ? const <String>[]
        : skillProblems(
            name: parsed.name ?? name,
            description: parsed.description,
            frontmatter: parsed.scalars,
            folderName: name,
          ),
    files: entries.where((e) => e.$1 != "SKILL.md").toList()
      ..sort((a, b) => a.$1.compareTo(b.$1)),
  );
}
