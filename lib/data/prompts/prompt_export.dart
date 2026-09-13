// Exporting a skill or agent as a file: the way out for an entry the app
// holds, wherever it holds it from. The inverse of the import the settings
// pages take in — a `.skill` zip for a skill, the `.md` file itself for an
// agent.
import "dart:convert";
import "dart:typed_data";

import "../../core/config.dart";
import "../../data/prompts/bundled_skill_data.dart"
    show bundledSkillFiles, bundledAgentFiles;
import "../../domain/bundled_prompt_file.dart" show BundledPromptFile, bundledPromptFileOf;
import "../../domain/models.dart";
import "../../domain/project.dart" show defaultProjectDir;
import "skill_import.dart";
import "skill_package.dart";

/// What the exported file is called: a `.skill` zip for a skill — the format
/// `parseSkillPackage` reads — and the agent's own `.md` otherwise.
String promptExportName(CompletionKind kind, String name) => switch (kind) {
      CompletionKind.skill => "$name.skill",
      CompletionKind.agent => "$name.md",
    };

/// The bytes a row's Export saves, in the order the library resolves the
/// entry: the page project's own directory, then a bundled preset (the
/// project's own tag over the default's), then the default project's
/// directory — the entry a project page badges Inherited. Null where none of
/// them hold it, which the UI says in a snack bar: the library lists what it
/// could not read the same way it lists what it can.
Future<Uint8List?> exportPromptBytes(
  AppConfig config,
  CompletionKind kind,
  String name, {
  String? project,
}) async {
  final fromOwn = await _fromDirectory(config, kind, name, project: project);
  if (fromOwn != null) return fromOwn;

  final bundled = bundledPromptFileOf(
    switch (kind) {
      CompletionKind.skill => bundledSkillFiles,
      CompletionKind.agent => bundledAgentFiles,
    },
    project,
    name,
  );
  if (bundled != null) return _fromBundled(kind, bundled);

  final fromDefault = project == null || project == defaultProjectDir
      ? null
      : await _fromDirectory(config, kind, name, project: defaultProjectDir);
  return fromDefault;
}

/// A `.skill` zip of [name]'s directory under its own folder — the shape the
/// import names a skill by, so one without a `name:` frontmatter in its
/// SKILL.md round-trips to the name it had here.
Future<Uint8List> _packageSkill(
  AppConfig config,
  String name, {
  String? project,
}) async {
  final fs = config.fs;
  final dir = skillDirectory(config, name, project: project);
  final fromDir = await packageSkillDirectory(fs, dir, null);
  final folder = fs.path.basename(dir);
  final entries = [
    for (final (path, data) in fromDir.entries) ("$folder/$path", data),
  ];
  return packageSkillBytes(SkillPackage(fromDir.name, entries));
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
    return _packageSkill(config, name, project: project);
  }
  final file = fs.file(_agentPath(config, name, project: project));
  if (!await file.exists()) return null;
  return Uint8List.fromList(await file.readAsBytes());
}

/// A bundled preset's bytes, from the embedded const rather than the disk —
/// the const is the source of truth, and the web has no directory to read.
/// A skill is packaged the way the install routes package one, under its own
/// folder: a SKILL.md with no `name:` frontmatter is named by the folder it
/// was zipped from, which is what gives the import its answer. An agent is
/// its own `.md`.
Uint8List _fromBundled(CompletionKind kind, BundledPromptFile bundled) {
  if (kind == CompletionKind.agent) {
    return Uint8List.fromList(utf8.encode(bundled.content));
  }
  final name = bundled.name;
  final entries = [
    for (final file in _bundledEntries(bundled.project, name))
      ("$name/${file.relativePath}",
          Uint8List.fromList(utf8.encode(file.content))),
  ];
  return packageSkillBytes(SkillPackage(name, entries));
}

/// Every embedded file of one bundled skill, whichever project it is tagged
/// with — the packager's walk over the const list.
List<BundledPromptFile> _bundledEntries(String project, String name) => [
      for (final file in bundledSkillFiles)
        if (file.project == project && file.name == name) file,
    ];

/// Where an agent called [name] lives — shared with the settings page's
/// writer, which is the import's other end.
String _agentPath(AppConfig config, String name, {String? project}) =>
    config.fs.path
        .join(config.promptsDir(CompletionKind.agent, project: project), "$name.md");