// Exporting a skill or agent as a file: the way out for an entry the app
// holds, wherever it holds it from. The inverse of the import the settings
// pages take in — a `.skill` zip for a skill, the `.md` file itself for an
// agent — and the resolver the skill view page reads its bytes through.
import "dart:typed_data";

import "../../core/config.dart";
import "../../data/prompts/bundled_skill_data.dart"
    show bundledSkillFiles, bundledAgentFiles;
import "../../data/zip.dart" show archiveOf;
import "../../domain/backup_handoff.dart";
import "../../domain/bundled_prompt_file.dart"
    show BundledPromptFile, bundledPromptFileOf, bundledPromptFilesOf;
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
Future<Uint8List?> exportPromptBytes(
  AppConfig config,
  CompletionKind kind,
  String name, {
  String? project,
}) async {
  final fromOwn = await _fromDirectory(config, kind, name, project: project);
  if (fromOwn != null) return fromOwn;

  if (project != null && project != defaultProjectDir) {
    final fromDefault =
        await _fromDirectory(config, kind, name, project: defaultProjectDir);
    if (fromDefault != null) return fromDefault;
  }

  final bundled = bundledPromptFileOf(
    switch (kind) {
      CompletionKind.skill => bundledSkillFiles,
      CompletionKind.agent => bundledAgentFiles,
    },
    project,
    name,
  );
  return bundled == null ? null : _fromBundled(kind, bundled);
}

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
  await handoff.save(promptExportName(kind, name), bytes);
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
  final own = await _skillEntries(config, name, project: project);
  if (own != null) return own;
  if (project != null && project != defaultProjectDir) {
    final inherited =
        await _skillEntries(config, name, project: defaultProjectDir);
    if (inherited != null) return inherited;
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
  final fs = config.fs;
  final dir = skillDirectory(config, name, project: project);
  if (!await fs.directory(dir).exists()) return null;
  final archive = await archiveOf(fs, [dir], base: dir);
  return [
    for (final file in archive)
      if (file.isFile) (file.name, file.readBytes() ?? Uint8List(0)),
  ];
}

/// A `.skill` zip of the skill directory at [dir] under its own folder — the
/// shape the import names a skill by, so one without a `name:` frontmatter
/// in its SKILL.md round-trips to the name it had here. No validation: export
/// is the way out for a folder the loader skipped, whatever is in it.
Future<Uint8List> _packageSkill(AppConfig config, String dir) async {
  final fs = config.fs;
  final archive = await archiveOf(fs, [dir], base: dir);
  final entries = [
    for (final file in archive)
      if (file.isFile) (file.name, file.readBytes() ?? Uint8List(0)),
  ];
  return _zipUnderFolder(
      fs.path.basename(dir), fs.path.basename(dir), entries);
}

/// [entries] under one folder named [folder], in a package called [name].
/// The one place the folder rule lives: the import takes a skill's name
/// from the folder its SKILL.md sits in, where the frontmatter has none.
Uint8List _zipUnderFolder(
    String folder, String name, List<(String, Uint8List)> entries) {
  final wrapped = [
    for (final (path, data) in entries) ("$folder/$path", data),
  ];
  return packageSkillBytes(SkillPackage(name, wrapped));
}

/// Where a skill or agent called [name] lives on [config]'s filesystem.
/// Null where it is not there: the caller falls through to the next source
/// the same way the library does.
Future<Uint8List?> _fromDirectory(
  AppConfig config,
  CompletionKind kind,
  String name, {
  String? project,
}) async {
  final fs = config.fs;
  if (kind == CompletionKind.skill) {
    final dir = skillDirectory(config, name, project: project);
    if (!await fs.directory(dir).exists()) return null;
    return _packageSkill(config, dir);
  }
  final file = fs.file(agentFilePath(config, name, project: project));
  if (!await file.exists()) return null;
  return file.readAsBytes();
}

/// A bundled preset's bytes, from the embedded const rather than the disk —
/// the const is the source of truth, and the web has no directory to read.
/// A skill is packaged through the same folder rule a directory export
/// takes; an agent is its own `.md`.
Uint8List _fromBundled(CompletionKind kind, BundledPromptFile bundled) {
  if (kind == CompletionKind.agent) {
    return Uint8List.fromList(bundled.bytes);
  }
  return _zipUnderFolder(
    bundled.name,
    bundled.name,
    [
      for (final file in bundledPromptFilesOf(
          bundledSkillFiles, bundled.project, bundled.name))
        (file.relativePath, Uint8List.fromList(file.bytes)),
    ],
  );
}