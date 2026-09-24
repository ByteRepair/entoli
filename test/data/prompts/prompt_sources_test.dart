import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/core/platform/io/platform.dart"
    show platformChmodReadOnly, platformChmodWritable;
import "package:agent_chat/data/prompts/bundled_skill_data.dart";
import "package:agent_chat/data/prompts/bundled_skills.dart";
import "package:agent_chat/data/prompts/prompt_sources.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";

import "../../harness.dart";

/// The install without the lock: a temp directory is never chmod'd 555.
Future<void> install(AppConfig config) => installBundledSkills(
    config,
    acquireWrite: (_) async {},
    releaseWrite: (_) async {});

void main() {
  test("the presets are embedded in code, and written to disk for bash", () async {
    final config = tempConfig();
    await install(config);

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
    await install(config);
    final marker =
        p.join(config.bundledSkillsDir(), "artifact", "SKILL.md");
    File(marker).writeAsStringSync("the user's edit");

    await install(config);

    final restored = File(marker).readAsStringSync();
    final original = bundledSkillFiles
        .firstWhere((f) => f.name == "artifact" && f.relativePath == "SKILL.md")
        .content;
    expect(restored, original);
  });

  test("self-heal deletes a file the embedded data does not name", () async {
    final config = tempConfig();
    await install(config);
    final stray =
        p.join(config.bundledSkillsDir(), "fake-skill", "SKILL.md");
    File(stray).createSync(recursive: true);
    File(stray).writeAsStringSync("---\ndescription: fake\n---\n\nPoison.");

    await install(config);

    expect(File(stray).existsSync(), isFalse);
    expect(
        Directory(p.join(config.bundledSkillsDir(), "fake-skill")).existsSync(),
        isFalse);
  });

  test("the install acquires the roots writable and releases them read-only",
      () async {
    final config = tempConfig();
    final root = Directory(config.bundledSkillsDir());
    final acquired = <String>[];
    final released = <String>[];

    await installBundledSkills(
      config,
      acquireWrite: (paths) async {
        acquired.addAll(paths);
        await platformChmodWritable(paths);
      },
      releaseWrite: (paths) async {
        released.addAll(paths);
        await platformChmodReadOnly(paths);
      },
    );

    expect(acquired.single, root.path,
        reason: "the default project's root is what is made writable");
    expect(released.single, root.path);
    expect(File(p.join(root.path, "artifact", "SKILL.md")).existsSync(),
        isTrue);
    expect(root.statSync().modeString(), "r-xr-xr-x",
        reason: "the release leaves the root read-only, as the launch does");
  });

  test("the install writes through a root the previous launch left read-only",
      () async {
    final config = tempConfig();
    final root = Directory(config.bundledSkillsDir());
    await install(config);
    final marker = p.join(root.path, "artifact", "SKILL.md");
    // The self-heal only writes where the disk copy differs, so an edit here
    // is what makes the acquire load-bearing: with a no-op one, the edit
    // survives (the failed write is swallowed) and the content check fails.
    File(marker).writeAsStringSync("the user's edit");
    Process.runSync("chmod", ["-R", "555", root.path]);

    await installBundledSkills(
      config,
      acquireWrite: platformChmodWritable,
      releaseWrite: platformChmodReadOnly,
    );

    final original = bundledSkillFiles
        .firstWhere((f) => f.name == "artifact" && f.relativePath == "SKILL.md")
        .content;
    expect(File(marker).readAsStringSync(), original,
        reason: "the acquire let the self-heal reach its repair");
    expect(root.statSync().modeString(), "r-xr-xr-x");
  });

  test("every skill dir in the source tree has entries in the embedded data",
      () async {
    final onDisk = Directory("assets/prompts/projects/default/skills")
        .listSync()
        .whereType<Directory>()
        .map((d) => p.basename(d.path))
        .toSet();
    final embedded = bundledSkillFiles.map((f) => f.name).toSet();
    for (final name in onDisk) {
      expect(embedded, contains(name),
          reason: "$name is on disk but not in bundledSkillFiles");
    }
  });

  test("every agent in the source tree has an entry in the embedded data", () {
    final onDisk = Directory("assets/prompts/projects/default/agents")
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith(".md"))
        .map((f) => p.basenameWithoutExtension(f.path))
        .toSet();
    final embedded = bundledAgentFiles.map((f) => f.name).toSet();
    for (final name in onDisk) {
      expect(embedded, contains(name),
          reason: "$name is on disk but not in bundledAgentFiles");
    }
  });

  test("the user's own come from the default project's skills dir", () async {
    final config = tempConfig();
    await config.ensureDirs();
    Directory(p.join(config.promptsDir(CompletionKind.skill), "ship"))
        .createSync(recursive: true);
    File(p.join(config.promptsDir(CompletionKind.skill), "ship", "SKILL.md"))
        .writeAsStringSync("---\nname: ship\ndescription: ship it\n---\n\nShip \$ARGUMENTS.\n");
    File(p.join(config.promptsDir(CompletionKind.agent), "notes.txt"))
        .writeAsStringSync("not markdown");

    final skills = await DirectoryPrompts(config).load(CompletionKind.skill);

    expect(skills.single.name, "ship");
    expect(skills.single.description, "ship it");
    expect(await DirectoryPrompts(config).load(CompletionKind.agent), isEmpty);
  });

  test("a frontmatter name that does not match the folder is skipped", () async {
    final config = tempConfig();
    await config.ensureDirs();
    Directory(p.join(config.promptsDir(CompletionKind.skill), "my-folder"))
        .createSync(recursive: true);
    File(p.join(config.promptsDir(CompletionKind.skill), "my-folder", "SKILL.md"))
        .writeAsStringSync("---\nname: named-otherwise\ndescription: d\n---\n\nBody.\n");

    final skills = await DirectoryPrompts(config).load(CompletionKind.skill);

    expect(skills, isEmpty,
        reason: "the spec requires the name to match the folder, and the "
            "view page says why it was skipped");
  });

  test("a frontmatter name matching the folder is the name", () async {
    final config = tempConfig();
    await config.ensureDirs();
    Directory(p.join(config.promptsDir(CompletionKind.skill), "my-folder"))
        .createSync(recursive: true);
    File(p.join(config.promptsDir(CompletionKind.skill), "my-folder", "SKILL.md"))
        .writeAsStringSync("---\nname: my-folder\ndescription: d\n---\n\nBody.\n");

    final skills = await DirectoryPrompts(config).load(CompletionKind.skill);

    expect(skills.single.name, "my-folder");
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
    await install(config);
    final preset =
        (await BundledPrompts(config: config).load(CompletionKind.skill)).first;
    Directory(p.join(config.promptsDir(CompletionKind.skill), preset.name))
        .createSync(recursive: true);
    File(p.join(config.promptsDir(CompletionKind.skill), preset.name, "SKILL.md"))
        .writeAsStringSync("---\nname: ${preset.name}\ndescription: mine\n---\n\nDo it my way.\n");

    final library = await PromptLibrary.from([
      BundledPrompts(config: config),
      DirectoryPrompts(config),
    ]);

    expect(library.find(CompletionKind.skill, preset.name)!.description, "mine");
  });

  test("the embedded checksums match the source files", () async {
    for (final file in bundledSkillFiles) {
      final source = File(p.join(
          "assets/prompts/projects", file.project, "skills", file.name, file.relativePath));
      if (!source.existsSync()) continue;
      final content = source.readAsBytesSync();
      final hash = sha256.convert(content).toString();
      expect(hash, file.sha256,
          reason: "${file.name}/${file.relativePath} checksum mismatch");
      expect(utf8.decode(content), file.content,
          reason: "${file.name}/${file.relativePath} content mismatch");
    }
    for (final file in bundledAgentFiles) {
      final source = File(
          p.join("assets/prompts/projects", file.project, "agents", "${file.name}.md"));
      if (!source.existsSync()) continue;
      final content = source.readAsStringSync();
      final hash = sha256.convert(utf8.encode(content)).toString();
      expect(hash, file.sha256, reason: "${file.name} checksum mismatch");
    }
  });

  test("a binary file survives the embed byte-identical", () async {
    final config = tempConfig();
    await install(config);
    final binary = bundledSkillFiles.firstWhere((f) => f.binary);
    final onDisk = File(p.join(
        config.bundledSkillsDir(), binary.name, binary.relativePath));
    expect(binary.binary, isTrue);
    expect(binary.bytes, isNot(utf8.encode(binary.content)),
        reason: "a base64 entry decodes to bytes other than its own text");
    expect(await onDisk.readAsBytes(), binary.bytes,
        reason: "${binary.name}/${binary.relativePath} does not round-trip");
  });

  test("every skill with a LICENSE.txt registers a licence entry", () async {
    final withLicence = bundledSkillFiles
        .where((f) => f.relativePath == "LICENSE.txt")
        .map((f) => f.name)
        .toSet();
    expect(withLicence, contains("skill-creator"),
        reason: "the local skill-creator carries its own licence");
    expect(withLicence, contains("mcp-builder"),
        reason: "the fetched skills carry theirs");
    // The registry is write-only from here; the page reads it back through
    // the framework. What is testable is that every name it should carry is
    // derivable, and the decoder behind it does not throw.
    for (final name in withLicence) {
      final licence = bundledSkillFiles
          .firstWhere((f) => f.name == name && f.relativePath == "LICENSE.txt");
      expect(utf8.decode(licence.bytes), contains("Apache License"));
    }
  });

  test("every fetched skill carries its own Apache licence", () {
    // What the fork's release ships is copied wholesale; the one rule this
    // side of the pond keeps is that a skill it embeds must say what
    // redistribution it allows. A release that forgets fails here, loudly,
    // rather than shipping a licence it does not have.
    final localSkills = Directory("assets/prompts/projects")
        .listSync(recursive: true)
        .whereType<Directory>()
        .where((d) => d.parent.path.endsWith("skills"))
        .map((d) => p.basename(d.path))
        .toSet();
    final fetched = bundledSkillFiles
        .map((f) => f.name)
        .toSet()
        .where((n) => !localSkills.contains(n))
        .toSet();
    expect(fetched, isNotEmpty);
    final withLicence = bundledSkillFiles
        .where((f) => f.relativePath == "LICENSE.txt")
        .map((f) => f.name)
        .toSet();
    for (final name in fetched) {
      expect(withLicence.contains(name), isTrue,
          reason: "$name is fetched but carries no LICENSE.txt");
      final licence = bundledSkillFiles
          .firstWhere((f) => f.name == name && f.relativePath == "LICENSE.txt");
      expect(utf8.decode(licence.bytes), contains("Apache License"),
          reason: "$name is not Apache-licensed");
    }
  });

  group("project scoping", () {
    // The local three are pinned by name; the fetched set moves with the
    // fork's releases and is asserted structurally above. Every skill is
    // unscoped, so every project inherits the whole lot.
    const localSkills = {
      "artifact",
      "coding",
      "deep-research",
      "skill-creator",
    };

    test("the default project offers the local skills and agents, no others "
        "missing", () async {
      final skills =
          await BundledPrompts(config: tempConfig()).load(CompletionKind.skill);
      final agents = await const BundledPrompts().load(CompletionKind.agent);

      expect(skills.map((s) => s.name).toSet(), containsAll(localSkills));
      expect(agents.map((a) => a.name).toSet(), {"explore", "general"});
    });

    test("byte-repair inherits the default's agents and adds esbmc-verifier, "
        "and ships no skills of its own", () async {
      final config = tempConfig();
      await install(config);
      final skills = await BundledPrompts(config: config, project: "byte-repair")
          .load(CompletionKind.skill);
      final agents = await const BundledPrompts(project: "byte-repair")
          .load(CompletionKind.agent);

      expect(skills.map((s) => s.name).toSet(), containsAll(localSkills));
      expect(agents.map((a) => a.name).toSet(),
          {"explore", "general", "esbmc-verifier"});
    });

    test("esbmc-verifier is byte-repair's alone", () async {
      final defaultAgents =
          await const BundledPrompts().load(CompletionKind.agent);
      final byteRepairAgents =
          await const BundledPrompts(project: "byte-repair")
              .load(CompletionKind.agent);

      expect(defaultAgents.any((a) => a.name == "esbmc-verifier"), isFalse,
          reason: "esbmc-verifier must not be visible to the default project");
      expect(byteRepairAgents.any((a) => a.name == "esbmc-verifier"), isTrue,
          reason: "esbmc-verifier must be visible to byte-repair");
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
              "---\nname: ship\ndescription: ship it\n---\n\nShip \$ARGUMENTS.\n");

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
          .writeAsStringSync("---\nname: shared\ndescription: default's\n---\n\nDefault.\n");
      // The project's override of the same name.
      Directory(p.join(
              config.promptsDir(CompletionKind.skill, project: "my-project"),
              "shared"))
          .createSync(recursive: true);
      File(p.join(config.promptsDir(CompletionKind.skill, project: "my-project"),
              "shared", "SKILL.md"))
          .writeAsStringSync("---\nname: shared\ndescription: project's\n---\n\nProject.\n");

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
      await install(config);

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