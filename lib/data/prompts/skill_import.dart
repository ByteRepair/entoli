// A `.skill` file is a zip of a skill directory — what skill-creator's
// `package_skill.py` writes, and what the Skills settings page takes in.
import "dart:convert";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:fs_shim/fs.dart";

import "../../core/config.dart";
import "../../data/prompts/bundled_skill_data.dart"
    show bundledSkillFiles, bundledAgentFiles;
import "../../domain/bundled_prompt_file.dart" show bundledPromptFileOf;
import "../../domain/models.dart";
import "../../domain/prompt_library.dart";
import "../../domain/project.dart" show projectLabel;
import "../../domain/workspace.dart";
import "skill_validate.dart";

/// Why a `.skill` file was refused. One line, meant for a snack bar — the
/// user picked the file, so the reason is theirs to read.
class SkillImportException implements Exception {
  const SkillImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A skill archive, decoded and named, not yet written anywhere.
class SkillPackage {
  SkillPackage(this.name, this.entries,
      {this.description, this.body = "", this.metadata = const {}});

  /// The frontmatter's `name` where the SKILL.md has one, the folder it was
  /// packaged from otherwise. What a skill is *called* and where it *lands*
  /// are the same string, so importing one twice replaces itself.
  final String name;

  /// The frontmatter `description` and the SKILL.md body, parsed once where the
  /// archive is decoded so a reader does not parse it again. Empty/null where
  /// the producer does not care (the packager zips and discards).
  final String? description;
  final String body;

  /// The nested `metadata:` map, parsed once with the rest.
  final Map<String, String> metadata;

  /// Paths as they sit inside the skill's own directory — the top-level
  /// folder a zip of one adds is already taken off, so where it lands is not
  /// the packager's choice. Entry names come from the archive, so they go
  /// through [safeRelativePath] on the way out; see [installSkillPackage].
  final List<(String, Uint8List)> entries;
}

/// Where a skill called [name] lives: the user's skills directory of [project]
/// — the default project's where it is null. The folder is the skill's base
/// directory and is named by prompts, so the project it lands in is where its
/// files are.
String skillDirectory(AppConfig config, String name, {String? project}) =>
    config.fs.path
        .join(config.promptsDir(CompletionKind.skill, project: project), name);

/// Where an agent called [name] lives: the `.md` under [project]'s agents
/// directory — the default project's where it is null. The name is the file
/// name, which is what the writer, the remover, the importer and the exporter
/// all have to agree on.
String agentFilePath(AppConfig config, String name, {String? project}) =>
    config.fs.path
        .join(config.promptsDir(CompletionKind.agent, project: project), "$name.md");

/// Decode a `.skill` archive. Refused rather than repaired: not a zip, no
/// `SKILL.md`, or a name that is not a single directory segment — the folder
/// is the skill's base directory and is named by prompts, so anything else
/// would land it somewhere nothing reads.
SkillPackage parseSkillPackage(Uint8List bytes) {
  // A zip opens with the "PK" local-file-header signature. The decoder would
  // say so only by finding no files at all, which is a weaker reason to refuse
  // than the one the user is owed when they picked the wrong kind of file.
  if (bytes.length < 2 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
    throw const SkillImportException("it is not a zip file");
  }
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const SkillImportException("it is not a zip file");
  }

  // The shallowest SKILL.md names the skill's root; a zip of a folder puts it
  // one down, and a deeper one is a skill packaged beside something else.
  final files = [
    for (final member in archive)
      if (!member.isDirectory) (member.name, member.readBytes() ?? Uint8List(0)),
  ];
  final roots = [
    for (final (name, _) in files)
      if (name.split("/").last == "SKILL.md") name,
  ]..sort((a, b) => a.length - b.length);
  if (roots.isEmpty) {
    throw const SkillImportException("there is no SKILL.md in it");
  }
  final root = roots.first;
  final prefix = root == "SKILL.md" ? "" : root.substring(0, root.length - "SKILL.md".length);
  final entries = [
    for (final (name, data) in files)
      if (name.startsWith(prefix)) (name.substring(prefix.length), data),
  ];

  final skillMd = entries.firstWhere((e) => e.$1 == "SKILL.md").$2;
  final document = PromptDocument.parse(
    CompletionKind.skill,
    "",
    utf8.decode(skillMd),
  );
  final name = document.frontmatter["name"] ?? prefix.replaceAll("/", "");
  if (!isFolderName(name)) {
    throw const SkillImportException("its name cannot be a folder name");
  }
  // Strict against the Agent Skills spec: a package that does not conform is
  // refused with the reasons rather than installed and rendered oddly. The
  // name it lands under is the name the validator checked, so the folder rule
  // holds by construction.
  final problems = skillProblems(
    name: name,
    description: document.description,
    frontmatter: document.frontmatter,
  );
  if (problems.isNotEmpty) {
    throw SkillImportException(problems.join("; "));
  }
  return SkillPackage(name, entries,
      description: document.description,
      body: document.body,
      metadata: document.metadata);
}

/// One directory under `skills/` and nothing else: a name holding a separator
/// would reach outside it, and a dot-name is invisible to nothing but the eye.
/// The agents settings page holds agent file names to the same rule. Not the
/// spec's name rule — that is [skillProblems]' — just the shape a folder name
/// can have.
bool isFolderName(String name) =>
    name.isNotEmpty && !name.startsWith(".") && !name.contains("/") && !name.contains("\\");

/// Whether [name] is a preset the binary embeds for [kind]: bundled skills for
/// [CompletionKind.skill], bundled agents for [CompletionKind.agent]. A
/// project's directory ships no [kind] entry of its own and the name is one
/// the embedded const carries — default's set or the project's own tag — the
/// row that shows it is a bundled preset, not an inherited user entry. The
/// skill half reads the const alone; its disk copy under `skills-bundled/` is
/// a cache the library never reads.
bool isBundledPromptName(CompletionKind kind, String name, {String? project}) =>
    bundledPromptFileOf(
      switch (kind) {
        CompletionKind.skill => bundledSkillFiles,
        CompletionKind.agent => bundledAgentFiles,
      },
      project,
      name,
    ) != null;

/// What a snack bar says a skill landed as: the bare sentence for the default
/// project, the destination named otherwise. Shared by the settings page's
/// import flow and the install preview page, so the two doors word it alike.
String installedSnack(String verb, String name, String? project) =>
    project == null ? "$verb $name." : "$verb $name to ${projectLabel(project)}.";

/// Write [package] into [project]'s skills directory — the default project's
/// where it is null. A skill already there of the same name is replaced
/// wholesale — delete first, so a re-imported skill does not keep the files
/// its new packaging dropped.
Future<void> installSkillPackage(AppConfig config, SkillPackage package,
    {String? project}) async {
  final fs = config.fs;
  final dir = skillDirectory(config, package.name, project: project);
  try {
    await fs.directory(dir).delete(recursive: true);
  } on FileSystemException {
    // Nothing there yet: that is the first import, not a failure.
  }
  for (final (name, data) in package.entries) {
    final target = fs.path.join(dir, safeRelativePath(fs, name));
    await fs.file(target).create(recursive: true);
    await fs.file(target).writeAsBytes(data);
  }
}
