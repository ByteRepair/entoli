// Packaging a skill from a workspace directory: the inverse of
// `installSkillPackage`, used by the `create_skill` tool to offer a drafted
// skill for install, and by `prompt_export.dart` to re-zip one.
import "dart:io";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:path/path.dart" as p;

import "../../domain/models.dart";
import "../../domain/prompt_library.dart";
import "../zip.dart";
import "skill_import.dart";
import "skill_validate.dart";

/// Reads the skill directory at [dir] (an absolute path on the config's
/// filesystem) and builds a [SkillPackage] from it. The [name] overrides the
/// directory's folder name where one is given; otherwise the folder is the
/// name, unless the SKILL.md frontmatter names one. Throws
/// [SkillImportException] where the SKILL.md does not conform — the
/// `create_skill` tool's packageSkill is the one caller, and the agent words
/// the refusal.
///
/// [prompt_export.dart] deliberately does not ride this: export packages
/// whatever sits in the folder, since that is the way out for a skill the
/// loader skipped.
Future<SkillPackage> packageSkillDirectory(String dir, String? name) async {
  final folderName = p.basename(dir);
  final skillMdFile = File(p.join(dir, "SKILL.md"));
  final skillMdContent = await skillMdFile.readAsString();
  final parsed = PromptDocument.parse(
    CompletionKind.skill,
    folderName,
    skillMdContent,
  );
  final skillName = name ?? parsed.frontmatter["name"] ?? folderName;
  final problems = skillProblems(
    name: skillName,
    description: parsed.description,
    frontmatter: parsed.frontmatter,
  );
  if (problems.isNotEmpty) {
    throw SkillImportException(problems.join("; "));
  }

  final archive = await archiveOf([dir], base: dir);
  final entries = [
    for (final file in archive)
      if (file.isFile) (file.name, file.readBytes() ?? Uint8List(0)),
  ];

  return SkillPackage(
    skillName,
    entries,
    description: parsed.description,
    body: parsed.body,
  );
}

/// Encodes a [SkillPackage] as a `.skill` zip — the same format
/// [parseSkillPackage] reads and `installSkillPackage` writes from.
Uint8List packageSkillBytes(SkillPackage package) {
  final archive = Archive();
  for (final (name, data) in package.entries) {
    archive.addFile(ArchiveFile.bytes(name, data));
  }
  return ZipEncoder().encodeBytes(archive);
}
