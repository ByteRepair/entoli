import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/core/platform/io/platform.dart"
    show platformChmodReadOnly, platformChmodWritable;
import "package:agent_chat/data/prompts/agent_pictures.dart";
import "package:agent_chat/domain/bundled_prompt_file.dart";
import "package:agent_chat/data/prompts/bundled_skill_data.dart";
import "package:agent_chat/data/prompts/bundled_skills.dart";
import "package:agent_chat/data/prompts/prompt_sources.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/domain/project_settings.dart";

import "../../harness.dart";

/// The chmod lock is a deliberate no-op where there is no bash for a model to
/// write through — `platformChmodReadOnly` runs on Linux and Android alone —
/// so the two assertions about the release and the write-through have nothing
/// to assert on macOS and Windows.
final _skipWithoutChmodLock = Platform.isLinux || Platform.isAndroid
    ? null
    : "the chmod lock is a no-op on this platform, so the read-only release "
        "cannot be asserted";

/// The install without the lock: a temp directory is never chmod'd 555.
Future<void> install(AppConfig config) => installBundledSkills(
    config,
    acquireWrite: (_) async {},
    releaseWrite: (_) async {});

/// A project directory on disk with its `project.json` seeded the way the
/// settings page writes it — through [ProjectSettings.save], which is
/// `documents.write` underneath.
Future<void> seedProject(AppConfig config, String project,
    {required bool omada}) async {
  Directory(config.projectDir(project: project)).createSync(recursive: true);
  await (ProjectSettings()..omada = omada).save(config, project: project);
}

/// One agent file in [project]'s `agents/` directory.
void seedAgent(AppConfig config, String project, String name,
    String description) {
  final dir = Directory(config.promptsDir(CompletionKind.agent, project: project));
  dir.createSync(recursive: true);
  File(p.join(dir.path, "$name.md"))
      .writeAsStringSync("---\ndescription: $description\n---\n\n$name.\n");
}

void main() {
  test("the presets are embedded in code, and written to disk for bash", () async {
    final config = tempConfig();
    await install(config);

    final skills =
        await BundledPrompts(config: config).load(CompletionKind.skill);
    final agents = await BundledPrompts().load(CompletionKind.agent);

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
  }, skip: _skipWithoutChmodLock);

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
  }, skip: _skipWithoutChmodLock);

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

  test("a binary entry decodes to its own bytes, not its own text", () {
    const bytes = [0x89, 0x50, 0x4e, 0x47, 0x00, 0xff];
    final entry = BundledPromptFile("default", "picture", "image.png",
        sha256.convert(bytes).toString(), base64Encode(bytes),
        binary: true);
    expect(entry.bytes, bytes);
    expect(entry.bytes, isNot(utf8.encode(entry.content)),
        reason: "a base64 entry's bytes are not the base64 itself");
  });

  test("every skill with a LICENSE.txt registers a licence entry", () async {
    final withLicence = bundledSkillFiles
        .where((f) => f.relativePath == "LICENSE.txt")
        .map((f) => f.name)
        .toSet();
    expect(withLicence, contains("skill-creator"),
        reason: "skill-creator carries its own licence");
    // The registry is write-only from here; the page reads it back through
    // the framework. What is testable is that every name it should carry is
    // derivable, and the decoder behind it does not throw.
    for (final name in withLicence) {
      final licence = bundledSkillFiles
          .firstWhere((f) => f.name == name && f.relativePath == "LICENSE.txt");
      expect(utf8.decode(licence.bytes), contains("Apache License"));
    }
  });

  group("project scoping", () {
    // The presets are the locally written skills, pinned by name in
    // full: nothing the marketplace serves ships built in. Every local
    // skill is unscoped, so every project inherits the whole lot.
    const localSkills = {
      "artifact",
      "code-review",
      "coding",
      "compact",
      "deep-research",
      "refactor",
      "simplify",
      "skill-creator",
    };

    test("the default project offers the local skills and agents, no others",
        () async {
      final skills =
          await BundledPrompts(config: tempConfig()).load(CompletionKind.skill);
      final agents = await BundledPrompts().load(CompletionKind.agent);

      expect(skills.map((s) => s.name).toSet(), equals(localSkills));
      expect(agents.map((a) => a.name).toSet(), {"explore", "general"});
    });

    test("byte-repair inherits the default's agents and adds esbmc-verifier, "
        "and ships no skills of its own", () async {
      final config = tempConfig();
      await install(config);
      final skills = await BundledPrompts(config: config, project: "byte-repair")
          .load(CompletionKind.skill);
      final agents = await BundledPrompts(project: "byte-repair")
          .load(CompletionKind.agent);

      expect(skills.map((s) => s.name).toSet(), equals(localSkills));
      expect(agents.map((a) => a.name).toSet(),
          {"explore", "general", "esbmc-verifier"});
    });

    test("My Team inherits the default's agents and ships none of its own",
        () async {
      final agents =
          await BundledPrompts(project: "my-team").load(CompletionKind.agent);

      expect(agents.map((a) => a.name).toSet(), {"explore", "general"});
    });

    test("an Omada-on user project inherits My Team's agents, an off one does not",
        () async {
      final config = tempConfig();
      await config.ensureDirs();
      // My Team's own agent directory: a project dir is one the user writes
      // into only through the app, so the test writes it directly.
      await seedProject(config, "on-team", omada: true);
      await seedProject(config, "off-team", omada: false);
      seedAgent(config, "my-team", "scout", "the scout");

      final on = await PromptLibrary.from([
        BundledPrompts(project: "on-team"),
        DirectoryPrompts(config, project: "on-team"),
      ]);
      final off = await PromptLibrary.from([
        BundledPrompts(project: "off-team"),
        DirectoryPrompts(config, project: "off-team"),
      ]);

      expect(on.find(CompletionKind.agent, "scout"), isNotNull,
          reason: "an Omada project inherits the Omada base's agents");
      expect(off.find(CompletionKind.agent, "scout"), isNull,
          reason: "an Omada-off project sees nothing of My Team's");
    });

    test("a project's own agent overrides a same-named My Team one", () async {
      final config = tempConfig();
      await config.ensureDirs();
      await seedProject(config, "team", omada: true);
      seedAgent(config, "my-team", "scout", "the base's");
      seedAgent(config, "team", "scout", "the team's");

      final library = await PromptLibrary.from([
        BundledPrompts(project: "team"),
        DirectoryPrompts(config, project: "team"),
      ]);

      expect(library.find(CompletionKind.agent, "scout")!.description,
          "the team's");
    });

    test("a project's own agent overrides a same-named default one", () async {
      final config = tempConfig();
      await config.ensureDirs();
      // A user-written agent in the default project's dir overrides the bundled
      // explore for the default project.
      File(p.join(config.promptsDir(CompletionKind.agent), "explore.md"))
          .writeAsStringSync("---\ndescription: mine\n---\n\nMy explore.\n");

      final library = await PromptLibrary.from([
        BundledPrompts(),
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
        BundledPrompts(project: "my-project"),
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
        BundledPrompts(project: "my-project"),
        DirectoryPrompts(config, project: "my-project"),
      ]);

      expect(library.find(CompletionKind.skill, "shared")!.description,
          "project's");
    });
  });

  group("agent pictures", () {
    void seedPicture(AppConfig config, String project, String name,
        List<int> bytes) {
      final dir =
          Directory(config.promptsDir(CompletionKind.agent, project: project));
      dir.createSync(recursive: true);
      File(p.join(dir.path, "$name.png")).writeAsBytesSync(bytes);
    }

    test("the picture reads from where the .md reads — the project's own "
        "answers over the default's", () async {
      final config = tempConfig();
      await config.ensureDirs();
      seedPicture(config, "default", "scout", [1]);
      seedPicture(config, "work", "scout", [2, 2]);

      final tiers = promptTiers(project: "work", config: config);
      expect(tiers, ["default", "work"]);

      expect(
        await readAgentPicture(config, "scout", tiers),
        [2, 2],
        reason: "the project's own picture wins, as its .md does",
      );
      expect(
        await readAgentPicture(config, "scout",
            promptTiers(project: null, config: config)),
        [1],
      );
    });

    test("an Omada rung's picture inherits the same way, and an off project "
        "sees nothing of it", () async {
      final config = tempConfig();
      await config.ensureDirs();
      await seedProject(config, "on-team", omada: true);
      await seedProject(config, "off-team", omada: false);
      seedPicture(config, "my-team", "scout", [7]);

      expect(
        await readAgentPicture(
            config, "scout", promptTiers(project: "on-team", config: config)),
        [7],
      );
      expect(
        await readAgentPicture(
            config, "scout", promptTiers(project: "off-team", config: config)),
        isNull,
      );
    });

    test("no tier holding one, and a missing file, are null rather than errors",
        () async {
      final config = tempConfig();
      await config.ensureDirs();
      final tiers = promptTiers(project: null, config: config);

      expect(await readAgentPicture(config, "scout", tiers), isNull);
      // A stray file with another extension is no picture — the .png alone is.
      Directory(config.promptsDir(CompletionKind.agent, project: null))
          .createSync(recursive: true);
      File(p.join(config.promptsDir(CompletionKind.agent), "scout.jpg"))
          .writeAsBytesSync([1]);
      expect(await readAgentPicture(config, "scout", tiers), isNull);
    });
  });
}