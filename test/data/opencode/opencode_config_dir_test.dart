import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/opencode/opencode_config_dir.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";

import "../../harness.dart";

void main() {
  test("commands and agents land where opencode globs for them", () {
    final config = tempConfig();
    final library = PromptLibrary([
      PromptDocument.parse(
          CompletionKind.command, "ship", "---\ndescription: ship it\n---\n\nShip \$ARGUMENTS.\n"),
      PromptDocument.parse(
          CompletionKind.agent, "scout", "---\nmode: subagent\n---\n\nYou scout.\n"),
    ]);

    writeOpencodeConfig(library, opencodeConfigDir(config));

    final dir = opencodeConfigDir(config).path;
    expect(File(p.join(dir, "command", "ship.md")).readAsStringSync(),
        contains("Ship \$ARGUMENTS."));
    expect(File(p.join(dir, "agent", "scout.md")).readAsStringSync(), contains("You scout."));
  });

  test("a rewrite drops what is no longer offered", () {
    final config = tempConfig();
    final before = PromptLibrary([
      PromptDocument.parse(CompletionKind.command, "gone", "---\n---\nold"),
    ]);
    writeOpencodeConfig(before, opencodeConfigDir(config));

    writeOpencodeConfig(
      PromptLibrary([PromptDocument.parse(CompletionKind.command, "kept", "---\n---\nnew")]),
      opencodeConfigDir(config),
    );

    final commands = Directory(p.join(opencodeConfigDir(config).path, "command"))
        .listSync()
        .map((e) => p.basename(e.path));
    expect(commands, ["kept.md"]);
  });

  test("an empty library still leaves the directories behind", () {
    final config = tempConfig();

    writeOpencodeConfig(PromptLibrary.empty, opencodeConfigDir(config));

    expect(Directory(p.join(opencodeConfigDir(config).path, "command")).existsSync(), isTrue);
    expect(Directory(p.join(opencodeConfigDir(config).path, "agent")).existsSync(), isTrue);
  });

  test("the server is pointed at the cache directory, not the user's config", () {
    final config = tempConfig();

    final env = opencodeEnvironment(config);

    expect(env["XDG_CONFIG_HOME"], config.cacheDir.path);
    expect(p.join(env["XDG_CONFIG_HOME"]!, "opencode"), opencodeConfigDir(config).path);
  });

  test("the user's own variables ride along, but cannot undo the isolation", () {
    final config = tempConfig();

    final env = opencodeEnvironment(config, extra: {
      "ANTHROPIC_API_KEY": "sk-test",
      "XDG_CONFIG_HOME": "/home/someone/.config",
    });

    expect(env["ANTHROPIC_API_KEY"], "sk-test");
    expect(env["XDG_CONFIG_HOME"], config.cacheDir.path);
  });
}
