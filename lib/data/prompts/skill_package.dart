// Packaging a skill from a workspace directory: the inverse of
// `installSkillPackage`, used by the `create_skill` tool to offer a drafted
// skill for install, and by `prompt_export.dart` to re-zip one.
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:fs_shim/fs.dart";

import "../../domain/models.dart";
import "../../domain/prompt_library.dart";
import "skill_import.dart";
import "skill_validate.dart";

/// Reads the skill directory at [dir] (an absolute path on the config's
/// filesystem) and builds a [SkillPackage] from it. The [name] overrides the
/// directory's folder name where one is given; otherwise the folder is the
/// name, unless the SKILL.md frontmatter names one. Throws [SkillImportException]
/// where the SKILL.md does not conform — the same refusal the settings import
/// gives, so a draft the `create_skill` tool packages is held to the spec
/// before the user is ever offered a card.
Future<SkillPackage> packageSkillDirectory(
    FileSystem fs, String dir, String? name) async {
  final path = fs.path;
  final folderName = path.basename(dir);
  final skillMdFile = fs.file(path.join(dir, "SKILL.md"));
  final skillMdContent = await skillMdFile.readAsString();
  final parsed = PromptDocument.parse(
      CompletionKind.skill, folderName, skillMdContent);
  final skillName = name ?? parsed.frontmatter["name"] ?? folderName;
  final problems = skillProblems(
    name: skillName,
    description: parsed.description,
    frontmatter: parsed.frontmatter,
  );
  if (problems.isNotEmpty) {
    throw SkillImportException(problems.join("; "));
  }

  final entries = <(String, Uint8List)>[];
  final files = <(String, File)>[];
  await _collectFiles(fs, dir, dir, files);
  final contents = await Future.wait([for (final (_, f) in files) f.readAsBytes()]);
  for (var i = 0; i < files.length; i++) {
    entries.add((files[i].$1, contents[i]));
  }

  return SkillPackage(skillName, entries,
      description: parsed.description,
      body: parsed.body,
      metadata: parsed.metadata);
}

Future<void> _collectFiles(FileSystem fs, String dir, String root,
    List<(String, File)> entries) async {
  final path = fs.path;
  await for (final entity in fs.directory(dir).list()) {
    if (entity is File) {
      entries.add((path.relative(entity.path, from: root), entity));
    } else if (entity is Directory) {
      await _collectFiles(fs, entity.path, root, entries);
    }
  }
}

/// Encodes a [SkillPackage] as a `.skill` zip — the same format
/// `parseSkillPackage` reads and `installSkillPackage` writes from.
Uint8List packageSkillBytes(SkillPackage package) {
  final archive = Archive();
  for (final (name, data) in package.entries) {
    archive.addFile(ArchiveFile.bytes(name, data));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}