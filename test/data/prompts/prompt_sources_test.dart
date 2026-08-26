import "dart:io";

import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/prompts/bundled_skills.dart";
import "package:agent_chat/data/prompts/prompt_sources.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";

import "../../harness.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("the presets are packaged with the app, and extracted to read", () async {
    final config = tempConfig();
    await installBundledSkills(config);

    final skills = await BundledPrompts(config: config).load(CompletionKind.skill);
    final agents = await const BundledPrompts().load(CompletionKind.agent);

    expect(skills, isNotEmpty);
    expect(agents, isNotEmpty);
    // A preset with no description would be a blank row in the menu.
    for (final document in [...skills, ...agents]) {
      expect(document.description, isNotNull, reason: "${document.name} has no description");
      expect(document.body, isNotEmpty, reason: "${document.name} has no body");
    }
    // A skill's body carries its base directory: the one thing every reader
    // needs and none of them can work out.
    for (final skill in skills) {
      expect(
        skill.body,
        startsWith("Base directory for this skill: ${p.join(config.bundledSkillsDir, skill.name)}"),
        reason: "${skill.name} does not name where its files are",
      );
    }
  });

  test("extraction leaves an already-extracted file alone", () async {
    final config = tempConfig();
    await installBundledSkills(config);
    final marker = p.join(config.bundledSkillsDir, "artifact", "SKILL.md");
    File(marker).writeAsStringSync("the user's edit");

    await installBundledSkills(config);

    expect(File(marker).readAsStringSync(), "the user's edit");
  });

  test("every bundled skill is declared in pubspec", () async {
    // An asset directory does not include its subdirectories, so a skill
    // added without an entry there does not ship — and nothing else would
    // say so.
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final shipped = manifest
        .listAssets()
        .where((k) => k.startsWith("assets/prompts/skills/"))
        .toSet();
    final onDisk = Directory("assets/prompts/skills")
        .listSync()
        .whereType<Directory>()
        .map((d) => p.basename(d.path));
    for (final name in onDisk) {
      expect(shipped, contains("assets/prompts/skills/$name/SKILL.md"),
          reason: "$name has no pubspec asset entry");
    }
  });

  test("the user's own come from \$AGENT_CHAT_CONFIG/skills", () async {
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

  test("a directory that does not exist yet offers nothing", () async {
    final config = tempConfig();

    expect(await DirectoryPrompts(config).load(CompletionKind.skill), isEmpty);
    expect(await BundledPrompts(config: config).load(CompletionKind.skill), isEmpty);
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
}
