// Exporting a skill or agent as a file: the way out for an entry the app
// holds, wherever it holds it from. The inverse of the import the settings
// pages take in — a `.skill` zip for a skill, the `.md` file itself for an
// agent — and the resolver the skill view page reads its bytes through.
import "dart:io";
import "dart:typed_data";

import "../../core/config.dart";
import "../../data/prompts/bundled_skill_data.dart"
    show bundledSkillFiles, bundledAgentFiles;
import "../../data/zip.dart" show archiveOf;
import "../../domain/backup_handoff.dart";
import "../../domain/bundled_prompt_file.dart"
    show bundledPromptFileOf, bundledPromptFilesOf;
import "../../domain/models.dart";
import "../../domain/project.dart" show defaultProjectDir;
import "skill_import.dart"
    show SkillImportException, SkillPackage, skillDirectory, agentFilePath;
import "skill_package.dart" show packageSkillBytes;

/// What the exported file is called: a `.skill` zip for a skill — the format
/// `parseSkillPackage` reads — and the agent's own `.md` otherwise.
String promptExportName(CompletionKind kind, String name) => switch (kind) {
      CompletionKind.skill => "$name.skill",
      CompletionKind.agent => "$name.md",
    };

/// The bytes a row's Export saves, in the order the library serves the entry:
/// the page project's own directory, then the default project's — the entry a
/// project page badges Inherited — then a bundled preset, the project's own
/// tag over the default's. Null where none of them hold it, which the UI says
/// in a snack bar: the library lists what it could not read the same way it
/// lists what it can.
///
/// A skill goes out as a `.skill` zip under its own folder — the shape the
/// import names a skill by, so one without a `name:` round-trips to the name
/// it had here. No validation: export is the way out for a folder the loader
/// skipped, whatever is in it.
Future<Uint8List?> exportPromptBytes(
  AppConfig config,
  CompletionKind kind,
  String name, {
  String? project,
}) async {
  if (kind == CompletionKind.skill) {
    final entries = await skillSourceEntries(config, name, project: project);
    return entries == null
        ? null
        : packageSkillBytes(SkillPackage(name, [
            for (final (path, data) in entries) ("$name/$path", data),
          ]));
  }
  for (final tier in _ownThenDefault(project)) {
    final file = File(agentFilePath(config, name, project: tier));
    if (file.existsSync()) return file.readAsBytes();
  }
  final bundled = bundledPromptFileOf(bundledAgentFiles, project, name);
  return bundled == null ? null : Uint8List.fromList(bundled.bytes);
}

/// The page project's own directory, then the default project's.
List<String?> _ownThenDefault(String? project) => [
      project,
      if (project != null && project != defaultProjectDir) defaultProjectDir,
    ];

/// Resolve, name and hand off an export — the whole flow both settings
/// pages' Export buttons run, so the route out and the refusal are said
/// once. Throws where no source holds the entry; `BackupHandoff.save`
/// answers silently when the user cancels the save.
Future<void> exportAndSave(
  AppConfig config,
  BackupHandoff handoff,
  CompletionKind kind,
  String name, {
  String? project,
}) async {
  final bytes = await exportPromptBytes(config, kind, name, project: project);
  if (bytes == null) {
    throw const SkillImportException("its file could not be read");
  }
  await handoff.save(
      promptExportName(kind, name), (path) => File(path).writeAsBytes(bytes));
}

/// The skill's files as they sit inside its own directory, resolved the way
/// [exportPromptBytes] resolves them — the page project's own directory, then
/// the default project's, then a bundled preset — so a view page shows the
/// same bytes an export would save. Null where no source holds it.
Future<List<(String, Uint8List)>?> skillSourceEntries(
  AppConfig config,
  String name, {
  String? project,
}) async {
  for (final tier in _ownThenDefault(project)) {
    final entries = await _skillEntries(config, name, project: tier);
    if (entries != null) return entries;
  }
  final bundled = bundledPromptFileOf(bundledSkillFiles, project, name);
  if (bundled == null) return null;
  return [
    for (final file in bundledPromptFilesOf(
        bundledSkillFiles, bundled.project, bundled.name))
      (file.relativePath, Uint8List.fromList(file.bytes)),
  ];
}

/// The files under a skill's directory as relative-path bytes pairs, through
/// the one walker, the way [archiveOf] names them. Directories are left out:
/// [parseSkillPackage] takes files alone, so the two shapes agree.
Future<List<(String, Uint8List)>?> _skillEntries(
  AppConfig config,
  String name, {
  String? project,
}) async {
  final dir = skillDirectory(config, name, project: project);
  if (!Directory(dir).existsSync()) return null;
  final archive = await archiveOf([dir], base: dir);
  return [
    for (final file in archive)
      if (file.isFile) (file.name, file.readBytes() ?? Uint8List(0)),
  ];
}
