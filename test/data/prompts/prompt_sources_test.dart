import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/prompts/bundled_skill_data.dart";
import "package:agent_chat/data/prompts/bundled_skills.dart";
import "package:agent_chat/data/prompts/prompt_sources.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";

import "../../harness.dart";

void main() {
  test("the presets are embedded in code, and written to disk for bash", () async {
    final config = tempConfig();
    await installBundledSkills(config);

    final skills =
        await BundledPrompts(config: config).load(CompletionKind.skill);
    final agents = await const BundledPrompts().load(CompletionKind.agent);

    expect(skills, isNotEmpty);
    expect(agents, isNotEmpty);
    for (final document in [...skills, ...agents]) {
      expect(document.description, isNotNull,
          reason: "${document.name} has no description");
      expect(document.body, isNotEmpty, reason: "${document.name} has no body");
    }
    for (final skill in skills) {
      expect(
        skill.body,
        startsWith(
            "Base directory for this skill: ${p.join(config.bundledSkillsDir(), skill.name)}"),
        reason: "${skill.name} does not name where its files are",
      );
    }
  });

  test("self-heal repairs a file that was edited on disk", () async {
    final config = tempConfig();
    await installBundledSkills(config);
    final marker =
        p.join(config.bundledSkillsDir(), "artifact", "SKILL.md");
    File(marker).writeAsStringSync("the user's edit");

    await installBundledSkills(config);

    final restored = File(marker).readAsStringSync();
    final original = bundledPromptFiles
        .firstWhere((f) => f.name == "artifact" && f.relativePath == "SKILL.md")
        .content;
    expect(restored, original);
  });

  test("self-heal deletes a file the embedded data does not name", () async {
    final config = tempConfig();
    await installBundledSkills(config);
    final stray =
        p.join(config.bundledSkillsDir(), "fake-skill", "SKILL.md");
    File(stray).createSync(recursive: true);
    File(stray).writeAsStringSync("---\ndescription: fake\n---\n\nPoison.");

    await installBundledSkills(config);

    expect(File(stray).existsSync(), isFalse);
    expect(
        Directory(p.join(config.bundledSkillsDir(), "fake-skill")).existsSync(),
        isFalse);
  });

  test("every skill dir in the source tree has entries in the embedded data",
      () async {
    final onDisk = Directory("assets/prompts/projects/default/skills")
        .listSync()
        .whereType<Directory>()
        .map((d) => p.basename(d.path))
        .toSet();
    final embedded =
        bundledPromptFiles.map((f) => f.name).toSet();
    for (final name in onDisk) {
      expect(embedded, contains(name),
          reason: "$name is on disk but not in bundledPromptFiles");
    }
  });

  test("every agent in the source tree has an entry in the embedded data", () {
    final onDisk = Directory("assets/prompts/projects/default/agents")
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith(".md"))
        .map((f) => p.basenameWithoutExtension(f.path))
        .toSet();
    final embedded =
        bundledPromptFiles.map((f) => f.name).toSet();
    for (final name in onDisk) {
      expect(embedded, contains(name),
          reason: "$name is on disk but not in bundledPromptFiles");
    }
  });

  test("the user's own come from the default project's skills dir", () async {
    final config = tempConfig();
    await config.ensureDirs();
    Directory(p.join(config.promptsDir(CompletionKind.skill), "ship"))
        .createSync(recursive: true);
    File(p.join(config.promptsDir(CompletionKind.skill), "ship", "SKILL.md"))
        .writeAsStringSync("---\ndescription: ship it\n---\n\nShip \$ARGUMENTS.\n");
    File(p.join(config.promptsDir(CompletionKind.agent), "notes.txt"))
        .writeAsStringSync("not markdown");

    final skills = await DirectoryPrompts(config).load(CompletionKind.skill);

    expect(skills.single.name, "ship");
    expect(skills.single.description, "ship it");
    expect(await DirectoryPrompts(config).load(CompletionKind.agent), isEmpty);
  });

  test("a skill is named by its frontmatter over its folder", () async {
    final config = tempConfig();
    await config.ensureDirs();
    Directory(p.join(config.promptsDir(CompletionKind.skill), "my-folder"))
        .createSync(recursive: true);
    File(p.join(config.promptsDir(CompletionKind.skill), "my-folder", "SKILL.md"))
        .writeAsStringSync("---\nname: named-otherwise\ndescription: d\n---\n\nBody.\n");

    final skills = await DirectoryPrompts(config).load(CompletionKind.skill);

    expect(skills.single.name, "named-otherwise");
  });

  test("an empty user skills directory offers nothing from DirectoryPrompts",
      () async {
    final config = tempConfig();

    expect(await DirectoryPrompts(config).load(CompletionKind.skill), isEmpty);
  });

  test("BundledPrompts returns skills from embedded data even with no disk", () async {
    final config = tempConfig();

    final skills =
        await BundledPrompts(config: config).load(CompletionKind.skill);
    expect(skills, isNotEmpty);
  });

  test("a folder with no SKILL.md, and a stray file, are not skills", () async {
    final config = tempConfig();
    await config.ensureDirs();
    Directory(p.join(config.promptsDir(CompletionKind.skill), "empty")).createSync();
    File(p.join(config.promptsDir(CompletionKind.skill), "stray.md"))
        .writeAsStringSync("---\ndescription: d\n---\n\nNo SKILL.md around.\n");

    expect(await DirectoryPrompts(config).load(CompletionKind.skill), isEmpty);
  });

  test("a file the user wrote replaces the preset it shares a name with", () async {
    final config = tempConfig();
    await installBundledSkills(config);
    final preset =
        (await BundledPrompts(config: config).load(CompletionKind.skill)).first;
    Directory(p.join(config.promptsDir(CompletionKind.skill), preset.name))
        .createSync(recursive: true);
    File(p.join(config.promptsDir(CompletionKind.skill), preset.name, "SKILL.md"))
        .writeAsStringSync("---\ndescription: mine\n---\n\nDo it my way.\n");

    final library = await PromptLibrary.from([
      BundledPrompts(config: config),
      DirectoryPrompts(config),
    ]);

    expect(library.find(CompletionKind.skill, preset.name)!.description, "mine");
  });

  test("the embedded checksums match the source files", () async {
    for (final file in bundledPromptFiles) {
      final source = File(p.join(
          "assets/prompts/projects", file.project, "skills", file.name, file.relativePath));
      if (!source.existsSync()) continue;
      final content = source.readAsStringSync();
      final hash = sha256.convert(utf8.encode(content)).toString();
      expect(hash, file.sha256,
          reason: "${file.name}/${file.relativePath} checksum mismatch");
    }
    for (final file in bundledPromptFiles) {
      if (file.relativePath.isNotEmpty) continue; // agents only
      final source = File(
          p.join("assets/prompts/projects", file.project, "agents", "${file.name}.md"));
      if (!source.existsSync()) continue;
      final content = source.readAsStringSync();
      final hash = sha256.convert(utf8.encode(content)).toString();
      expect(hash, file.sha256, reason: "${file.name} checksum mismatch");
    }
  });

  group("project scoping", () {
    test("esbmc-verifier is byte-repair's alone", () async {
      // The default project inherits the base set and nothing of byte-repair's.
      final defaultAgents =
          await const BundledPrompts().load(CompletionKind.agent);
      final byteRepairAgents =
          await const BundledPrompts(project: "byte-repair")
              .load(CompletionKind.agent);

      expect(
          defaultAgents.any((a) => a.name == "esbmc-verifier"), isFalse,
          reason: "esbmc-verifier must not be visible to the default project");
      expect(byteRepairAgents.any((a) => a.name == "esbmc-verifier"), isTrue,
          reason: "esbmc-verifier must be visible to byte-repair");
      // Default's agents (explore, general) are still visible to byte-repair.
      expect(defaultAgents.any((a) => a.name == "explore"), isTrue);
      expect(byteRepairAgents.any((a) => a.name == "explore"), isTrue);
    });

    test("a project's own agent overrides a same-named default one", () async {
      final config = tempConfig();
      await config.ensureDirs();
      // A user-written agent in the default project's dir overrides the bundled
      // explore for the default project.
      File(p.join(config.promptsDir(CompletionKind.agent), "explore.md"))
          .writeAsStringSync("---\ndescription: mine\n---\n\nMy explore.\n");

      final library = await PromptLibrary.from([
        const BundledPrompts(),
        DirectoryPrompts(config),
      ]);

      expect(library.find(CompletionKind.agent, "explore")!.description, "mine");
    });

    test("a non-default project inherits the default's user skills", () async {
      final config = tempConfig();
      await config.ensureDirs();
      Directory(p.join(config.promptsDir(CompletionKind.skill), "ship"))
          .createSync(recursive: true);
      File(p.join(config.promptsDir(CompletionKind.skill), "ship", "SKILL.md"))
          .writeAsStringSync(
              "---\ndescription: ship it\n---\n\nShip \$ARGUMENTS.\n");

      // A project with no skills of its own sees the default's user skill.
      final library = await PromptLibrary.from([
        const BundledPrompts(project: "my-project"),
        DirectoryPrompts(config, project: "my-project"),
      ]);

      expect(library.find(CompletionKind.skill, "ship"), isNotNull);
    });

    test("a project's own skill overrides the default's same-named one", () async {
      final config = tempConfig();
      await config.ensureDirs();
      // Default's user skill.
      Directory(p.join(config.promptsDir(CompletionKind.skill), "shared"))
          .createSync(recursive: true);
      File(p.join(config.promptsDir(CompletionKind.skill), "shared", "SKILL.md"))
          .writeAsStringSync("---\ndescription: default's\n---\n\nDefault.\n");
      // The project's override of the same name.
      Directory(p.join(
              config.promptsDir(CompletionKind.skill, project: "my-project"),
              "shared"))
          .createSync(recursive: true);
      File(p.join(config.promptsDir(CompletionKind.skill, project: "my-project"),
              "shared", "SKILL.md"))
          .writeAsStringSync("---\ndescription: project's\n---\n\nProject.\n");

      final library = await PromptLibrary.from([
        const BundledPrompts(project: "my-project"),
        DirectoryPrompts(config, project: "my-project"),
      ]);

      expect(library.find(CompletionKind.skill, "shared")!.description,
          "project's");
    });

    test("self-heal writes a project's bundled skills to its own dir",
        () async {
      final config = tempConfig();
      await installBundledSkills(config);

      // byte-repair ships esbmc-verifier as a bundled *agent*, which is
      // code-only — never written to disk. So byte-repair's skills-bundled dir
      // exists (created by ensureProjectDirs) but holds no skills, since
      // byte-repair ships none. The default's holds the base set.
      final defaultDir =
          Directory(config.bundledSkillsDir());
      expect(await defaultDir.exists(), isTrue);
      expect(defaultDir.listSync().whereType<Directory>().map((d) => p.basename(d.path)),
          contains("artifact"));
    });
  });
}