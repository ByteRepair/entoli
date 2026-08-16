import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/prompts/prompt_sources.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";

import "../../harness.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("the presets are packaged with the app", () async {
    final commands = await const BundledPrompts().load(CompletionKind.command);
    final agents = await const BundledPrompts().load(CompletionKind.agent);

    expect(commands, isNotEmpty);
    expect(agents, isNotEmpty);
    // A preset with no description would be a blank row in the menu.
    for (final document in [...commands, ...agents]) {
      expect(document.description, isNotNull, reason: "${document.name} has no description");
      expect(document.body, isNotEmpty, reason: "${document.name} has no body");
    }
  });

  test("the user's own come from \$AGENT_CHAT_CONFIG", () async {
    final config = tempConfig();
    await config.ensureDirs();
    File(p.join(config.promptsDir(CompletionKind.command), "ship.md"))
        .writeAsStringSync("---\ndescription: ship it\n---\n\nShip \$ARGUMENTS.\n");
    File(p.join(config.promptsDir(CompletionKind.agent), "notes.txt"))
        .writeAsStringSync("not markdown");

    final commands = await DirectoryPrompts(config).load(CompletionKind.command);

    expect(commands.single.name, "ship");
    expect(commands.single.description, "ship it");
    expect(await DirectoryPrompts(config).load(CompletionKind.agent), isEmpty);
  });

  test("a directory that does not exist yet offers nothing", () async {
    final config = tempConfig();

    expect(await DirectoryPrompts(config).load(CompletionKind.command), isEmpty);
  });

  test("a file the user wrote replaces the preset it shares a name with", () async {
    final config = tempConfig();
    await config.ensureDirs();
    final preset = (await const BundledPrompts().load(CompletionKind.command)).first;
    File(p.join(config.promptsDir(CompletionKind.command), "${preset.name}.md"))
        .writeAsStringSync("---\ndescription: mine\n---\n\nDo it my way.\n");

    final library = await PromptLibrary.from([
      const BundledPrompts(),
      DirectoryPrompts(config),
    ]);

    expect(library.find(CompletionKind.command, preset.name)!.description, "mine");
  });
}
