import "dart:io";
import "dart:typed_data";

import "package:archive/archive.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/prompts/skill_import.dart";
import "package:agent_chat/domain/models.dart";

import "../../harness.dart";

/// A `.skill` zip from [files] of relative-path to content, wrapped in a
/// single top-level [folder] where one is given — the shape `package_skill.py`
/// writes.
Uint8List skillZip(Map<String, String> files, {String? folder}) {
  final archive = Archive();
  for (final entry in files.entries) {
    final name = folder == null ? entry.key : "$folder/${entry.key}";
    archive.add(ArchiveFile.string(name, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

const _skillMd = "---\nname: review\ndescription: look it over\n---\n\nReview \$ARGUMENTS.\n";

void main() {
  group("parseSkillPackage", () {
    test("names the skill by its frontmatter over the folder it came from", () {
      final package = parseSkillPackage(skillZip({
        "SKILL.md": "---\nname: review\ndescription: look it over\n---\n\nReview \$ARGUMENTS.\n",
        "scripts/run.sh": "#!/bin/sh\n",
      }, folder: "packaged"));

      expect(package.name, "review");
      expect(package.entries.map((e) => e.$1), containsAll(["SKILL.md", "scripts/run.sh"]));
      // The top folder is stripped, so nothing lands in a packager's sub-tree.
      expect(package.entries.map((e) => e.$1), isNot(contains("packaged/SKILL.md")));
    });

    test("without a name in the frontmatter, the folder is the name", () {
      final package = parseSkillPackage(skillZip(
          {"SKILL.md": "---\ndescription: d\n---\n\nBody.\n"},
          folder: "review"));

      expect(package.name, "review");
    });

    test("a package with no description is refused", () {
      expect(
        () => parseSkillPackage(
            skillZip({"SKILL.md": "---\nname: bare\n---\n\nBody.\n"})),
        throwsA(isA<SkillImportException>().having((e) => e.message, "message",
            "no description in the SKILL.md frontmatter")),
      );
    });

    test("the folder the package lands under is the name, not the zip's folder",
        () {
      final package = parseSkillPackage(skillZip({
        "SKILL.md": "---\nname: other-name\ndescription: d\n---\n\nBody.\n",
      }, folder: "review"));
      expect(package.name, "other-name");
    });

    test("a package with an unknown top-level key is refused", () {
      expect(
        () => parseSkillPackage(skillZip({
          "SKILL.md":
              "---\nname: review\ndescription: d\nargument-hint: args\n---\n\nBody.\n",
        }, folder: "review")),
        throwsA(isA<SkillImportException>().having(
            (e) => e.message,
            "message",
            contains('unknown frontmatter key "argument-hint"'))),
      );
    });

    test("a zip with no SKILL.md is refused", () {
      expect(
        () => parseSkillPackage(skillZip({"notes.md": "hi"})),
        throwsA(isA<SkillImportException>().having(
            (e) => e.message, "message", "there is no SKILL.md in it")),
      );
    });

    test("bytes that are not a zip are refused", () {
      expect(
        () => parseSkillPackage(Uint8List.fromList([0, 1, 2, 3])),
        throwsA(isA<SkillImportException>()
            .having((e) => e.message, "message", "it is not a zip file")),
      );
    });

    test("a name that cannot be a folder is refused", () {
      final package = skillZip(
        {"SKILL.md": "---\nname: a/b\ndescription: d\n---\n\nBody.\n"});
      expect(
        () => parseSkillPackage(package),
        throwsA(isA<SkillImportException>()
            .having((e) => e.message, "message", "its name cannot be a folder name")),
      );
    });
  });

  group("installSkillPackage", () {
    test("a skill lands in the user's skills directory", () async {
      final config = tempConfig();
      final package = parseSkillPackage(
          skillZip({"SKILL.md": _skillMd, "scripts/run.sh": "#!/bin/sh\n"}, folder: "review"));

      await installSkillPackage(config, package);

      final dir = p.join(config.promptsDir(CompletionKind.skill), package.name);
      expect(File(p.join(dir, "SKILL.md")).existsSync(), isTrue);
      expect(File(p.join(dir, "scripts", "run.sh")).existsSync(), isTrue);
    });

    test("re-importing replaces: a file the new packaging dropped is gone", () async {
      final config = tempConfig();
      final first = parseSkillPackage(
          skillZip({"SKILL.md": _skillMd, "obsolete.sh": "old\n"}, folder: "review"));
      await installSkillPackage(config, first);
      final second = parseSkillPackage(skillZip(
          {"SKILL.md": "---\nname: review\ndescription: v2\n---\n\nv2\n"},
          folder: "review"));

      await installSkillPackage(config, second);

      final dir = p.join(config.promptsDir(CompletionKind.skill), second.name);
      expect(File(p.join(dir, "obsolete.sh")).existsSync(), isFalse);
      expect(File(p.join(dir, "SKILL.md")).readAsStringSync(), contains("v2"));
    });

    test("an entry that tries to escape is kept inside the skill", () async {
      final config = tempConfig();
      final package = parseSkillPackage(skillZip({
        "SKILL.md": "---\nname: safe\ndescription: d\n---\n\nBody.\n",
        "../evil.txt": "escaped\n",
      }));

      await installSkillPackage(config, package);

      final skillsDir = config.promptsDir(CompletionKind.skill);
      expect(File(p.join(skillsDir, package.name, "evil.txt")).existsSync(), isTrue);
      // The path the entry named for itself did not reach the skills' parent.
      expect(File(p.join(skillsDir, "evil.txt")).existsSync(), isFalse);
      expect(File(p.join(p.dirname(skillsDir), "evil.txt")).existsSync(), isFalse);
    });
  });
}
