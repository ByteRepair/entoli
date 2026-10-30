import "dart:io";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/prompts/skill_import.dart";
import "package:agent_chat/data/prompts/skill_package.dart";

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp("skill-package");
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  void write(Map<String, String> files) {
    files.forEach((name, content) {
      final file = File("${dir.path}/$name");
      file.createSync(recursive: true);
      file.writeAsStringSync(content);
    });
  }

  group("packageSkillDirectory", () {
    test("reads the directory's files into a package, recursively", () async {
      write({
        "SKILL.md": "---\nname: demo\ndescription: does it\n---\n\nDo it.\n",
        "scripts/run.sh": "#!/bin/sh\necho hi\n",
        "references/notes.md": "notes\n",
      });

      final package = await packageSkillDirectory(dir.path, null);

      expect(package.name, "demo");
      final names = package.entries.map((e) => e.$1).toSet();
      expect(
        names,
        containsAll(["SKILL.md", "scripts/run.sh", "references/notes.md"]),
      );
    });

    test("a name argument wins over the frontmatter and the folder", () async {
      write({
        "SKILL.md":
            "---\nname: from-frontmatter\ndescription: d\n---\n\nDo it.\n",
      });

      final package = await packageSkillDirectory(dir.path, "from-arg");

      expect(package.name, "from-arg");

      // Without a name argument or frontmatter name, the folder is the name:
      // the folder is a temp dir whose name is not a spec name, so the
      // packager is handed the name the folder would be renamed to.
      write({"SKILL.md": "---\ndescription: d\n---\n\nDo it.\n"});
      final fromFolder = await packageSkillDirectory(dir.path, "demo");

      expect(fromFolder.name, "demo");
    });

    test(
      "a frontmatter that does not conform is refused with the reasons",
      () async {
        write({
          "SKILL.md":
              "---\nname: Demo\ndescription: d\nargument-hint: args\n---\n\nDo it.\n",
        });

        await expectLater(
          packageSkillDirectory(dir.path, null),
          throwsA(
            isA<SkillImportException>().having(
              (e) => e.message,
              "message",
              allOf(
                contains("name \"Demo\""),
                contains("unknown frontmatter key \"argument-hint\""),
              ),
            ),
          ),
        );
      },
    );
  });

  group("round trip", () {
    test("packageSkillBytes is a zip parseSkillPackage reads back", () async {
      write({
        "SKILL.md": "---\nname: demo\ndescription: does it\n---\n\nDo it.\n",
        "scripts/run.sh": "#!/bin/sh\necho hi\n",
      });

      final original = await packageSkillDirectory(dir.path, null);
      final bytes = packageSkillBytes(original);
      expect(bytes.length, greaterThan(0));

      final reparsed = parseSkillPackage(Uint8List.fromList(bytes));
      expect(reparsed.name, "demo");
      expect(reparsed.entries.map((e) => e.$1).toSet(), {
        "SKILL.md",
        "scripts/run.sh",
      });
      // The bytes survived the trip intact.
      final skillMd = reparsed.entries.firstWhere((e) => e.$1 == "SKILL.md").$2;
      expect(utf8(skillMd), contains("Do it."));
    });
  });
}

String utf8(List<int> bytes) => String.fromCharCodes(bytes);
