import "dart:convert";
import "dart:io";

import "package:archive/archive.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/prompts/prompt_export.dart";
import "package:agent_chat/data/prompts/skill_import.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/project.dart" show defaultProjectDir;

import "../../harness.dart";

void main() {
  late AppConfig config;

  setUp(() => config = tempConfig());

  group("promptExportName", () {
    test("a skill is a .skill, an agent its own .md", () {
      expect(promptExportName(CompletionKind.skill, "review"), "review.skill");
      expect(promptExportName(CompletionKind.agent, "researcher"),
          "researcher.md");
    });
  });

  group("exportPromptBytes", () {
    test("a user skill round-trips through the import parser", () async {
      await writeAgentChatSkill(config, "review", project: "work");
      final bytes =
          await exportPromptBytes(config, CompletionKind.skill, "review", project: "work");
      expect(bytes, isNotNull);

      final package = parseSkillPackage(bytes!);
      expect(package.name, "review");
      expect(package.body, contains("Do review."));
    }, timeout: testTimeout);

    test("a skill the loader skipped exports anyway — export is its way out",
        () async {
      final dir = skillDirectory(config, "broken", project: "work");
      final file = File("$dir/SKILL.md");
      await file.create(recursive: true);
      await file.writeAsString("---\nname: broken\n---\n\nNo description.\n");

      final bytes =
          await exportPromptBytes(config, CompletionKind.skill, "broken", project: "work");
      expect(bytes, isNotNull);
      // The zip holds the folder's files under the folder's own name. Only
      // the import, not the export, holds a package to the spec — the strict
      // parser would refuse these bytes, which is the point.
      final archive = ZipDecoder().decodeBytes(bytes!);
      expect(archive.files.map((f) => f.name),
          containsAll(["broken/SKILL.md"]));
    }, timeout: testTimeout);

    test("a bundled skill exports its SKILL.md under the skill's folder",
        () async {
      final bytes = await exportPromptBytes(config, CompletionKind.skill, "artifact");
      expect(bytes, isNotNull);

      final package = parseSkillPackage(bytes!);
      expect(package.name, "artifact");
      expect(package.body, isNot(contains("Base directory")));
      // The parser takes the folder off again — it is the folder it named
      // the skill by.
      expect(package.entries.map((e) => e.$1), contains("SKILL.md"));
    }, timeout: testTimeout);

    test("a project's inherited entry exports from the default project's "
        "directory", () async {
      await writeAgentChatSkill(config, "review");
      final bytes = await exportPromptBytes(
        config,
        CompletionKind.skill,
        "review",
        project: "work",
      );
      expect(bytes, isNotNull);
      expect(parseSkillPackage(bytes!).name, "review");
    }, timeout: testTimeout);

    test("a default-directory entry shadows the bundled preset it shares a "
        "name with, the way the library serves it", () async {
      // The bundled three do not carry this name, so the disk decides.
      await writeAgentChatSkill(config, "deep-research");
      final bytes = await exportPromptBytes(
        config,
        CompletionKind.skill,
        "deep-research",
        project: "work",
      );
      final package = parseSkillPackage(bytes!);
      expect(package.body, contains("Do deep-research."));
      expect(package.body, isNot(contains("interactive HTML artifact")));
    }, timeout: testTimeout);

    test("a user agent's export is the file itself", () async {
      final dir = config.promptsDir(CompletionKind.agent, project: "work");
      final file = File("$dir/researcher.md");
      await file.create(recursive: true);
      await file.writeAsString("---\ndescription: desc\n---\n\nBody.");

      final bytes = await exportPromptBytes(
        config,
        CompletionKind.agent,
        "researcher",
        project: "work",
      );
      expect(utf8.decode(bytes!), file.readAsStringSync());
    }, timeout: testTimeout);

    test("a bundled agent exports its embedded .md", () async {
      final bytes = await exportPromptBytes(config, CompletionKind.agent, "general");
      expect(bytes, isNotNull);
      expect(utf8.decode(bytes!), contains("description:"));
    }, timeout: testTimeout);

    test("an inherited agent exports from the default project's directory",
        () async {
      final file =
          File("${config.promptsDir(CompletionKind.agent)}/researcher.md");
      await file.create(recursive: true);
      await file.writeAsString("---\ndescription: desc\n---\n\nBody.");

      final bytes = await exportPromptBytes(
        config,
        CompletionKind.agent,
        "researcher",
        project: "work",
      );
      expect(utf8.decode(bytes!), contains("Body."));
    }, timeout: testTimeout);

    test("an entry nowhere answers null", () async {
      expect(
        exportPromptBytes(config, CompletionKind.skill, "nowhere"),
        completion(isNull),
      );
      expect(
        exportPromptBytes(config, CompletionKind.agent, "nowhere"),
        completion(isNull),
      );
    }, timeout: testTimeout);

    test("the exported skill imports back into another project", () async {
      await writeAgentChatSkill(config, "review", project: "work");
      final bytes =
          await exportPromptBytes(config, CompletionKind.skill, "review", project: "work");
      final package = parseSkillPackage(bytes!);

      await installSkillPackage(config, package, project: defaultProjectDir);
      final dir = Directory(skillDirectory(config, "review"));
      expect(dir.existsSync(), isTrue);
      expect(File("${dir.path}/SKILL.md").readAsStringSync(),
          contains("Do review."));
    }, timeout: testTimeout);
  });
}

const testTimeout = Timeout(Duration(seconds: 10));

Future<void> writeAgentChatSkill(
  AppConfig config,
  String name, {
  String? project,
}) async {
  final dir = skillDirectory(config, name, project: project);
  final file = File("$dir/SKILL.md");
  await file.create(recursive: true);
  await file
      .writeAsString("---\nname: $name\ndescription: do $name\n---\n\nDo $name.\n");
}