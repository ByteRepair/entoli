import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/core/migrations.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/project_settings.dart";
import "package:agent_chat/domain/temp_chat_ttl.dart";
import "package:agent_chat/domain/trigger.dart";
import "package:agent_chat/domain/tristate.dart";

import "../harness.dart";

/// 8.4.0, the entry that writes what the readers once took in an older shape
/// in today's: the files below read as they always did, through readers that
/// know one shape.
void main() {
  late String dataDir;

  setUp(() => dataDir = tempConfig().dataDir);

  File seed(String relative, Object json) =>
      File(p.joinAll([dataDir, ...relative.split("/")]))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(json));

  Object? read(File file) => jsonDecode(file.readAsStringSync());

  Future<void> migrate() => runMigrations(dataDir, fresh: false);

  test("settings under the names they had before move under today's", () async {
    final app = seed("settings.json", {
      "opencodeEnv": {"ANTHROPIC_API_KEY": "sk-old"},
      "approveCommands": false,
      "localModelKvCacheChats": 30,
    });
    final project = seed("projects/work/project.json", {
      "useProjectMemory": true,
    });
    final chat = seed("projects/work/chats/c1/meta.json", {
      "approveCommands": true,
    });

    await migrate();

    expect(read(app), {
      "environment": {"ANTHROPIC_API_KEY": "sk-old"},
      "approveMode": "never",
      "localModelKvCachePrompts": 30,
    });
    final settings = AppSettings.fromJson(read(app)! as Map<String, dynamic>);
    expect(settings.environment, {"ANTHROPIC_API_KEY": "sk-old"});
    expect(settings.approveMode, ApproveMode.never);
    expect(settings.localModelKvCachePrompts, 30);
    expect(
      ProjectSettings.fromJson(read(project)! as Map<String, dynamic>).memory,
      Tristate.on,
    );
    expect(read(chat), {"approveMode": "ask"});
    expect(
      ChatMeta.fromJson(read(chat)! as Map<String, dynamic>).approveMode,
      ApproveMode.ask,
    );
  });

  test("a setting already under today's name keeps its value", () async {
    final app = seed("settings.json", {
      "approveMode": "auto",
      "approveCommands": false,
    });
    final project = seed("projects/work/project.json", {
      "useProjectMemory": false,
    });

    await migrate();

    expect(read(app), {"approveMode": "auto"});
    // False was a store shared with the default project: inherit, unsaid.
    expect(read(project), <String, dynamic>{});
  });

  test("a provider entry from 7.0.0 or older gets its name and its "
      "models.dev id, and loses the key the reader never took", () async {
    final app = seed("settings.json", {
      "llmProviders": [
        {
          "id": "openrouter",
          "api": "openai",
          "baseUrl": "https://openrouter.ai/api/v1",
          "label": "OpenRouter",
          "apiKey": "sk-or-1",
        },
        {"id": "ollama", "api": "openai", "baseUrl": "http://localhost:11434"},
        {
          "id": "mine",
          "api": "openai",
          "baseUrl": "https://example.com",
          "name": "Mine",
        },
      ],
    });

    await migrate();

    final entries = (read(app)! as Map)["llmProviders"] as List;
    expect(entries[0], {
      "id": "openrouter",
      "api": "openai",
      "baseUrl": "https://openrouter.ai/api/v1",
      "name": "OpenRouter",
      "catalogId": "openrouter",
    });
    expect((entries[1] as Map)["name"], "ollama");
    expect((entries[1] as Map)["catalogId"], "ollama");
    // Today's shape is left as it was.
    expect(entries[2], {
      "id": "mine",
      "api": "openai",
      "baseUrl": "https://example.com",
      "name": "Mine",
    });
    final settings = AppSettings.fromJson(read(app)! as Map<String, dynamic>);
    expect(settings.llmProviders.first.displayName, "OpenRouter");
    expect(settings.llmProviders.first.catalogId, "openrouter");
  });

  test("a trigger in the reminder shape gets a source and its TTL", () async {
    final at = DateTime(2026, 1, 1, 9).toIso8601String();
    final file = seed("reminders.json", [
      {"id": "daily", "at": at, "repeat": "daily", "temporary": false},
      {"id": "once", "at": at, "temporary": true},
      {
        "id": "today",
        "source": {"kind": "timer", "seconds": 60},
        "tempChatTtl": "hours24",
      },
    ]);

    await migrate();

    final entries = read(file)! as List;
    final triggers = [
      for (final entry in entries)
        Trigger.fromJson(entry as Map<String, dynamic>),
    ];
    final daily = triggers[0].source as ScheduleSource;
    expect(daily.at, DateTime(2026, 1, 1, 9));
    expect(daily.repeat, ScheduleRepeat.daily);
    expect(triggers[0].tempChatTtl, TempChatTtl.off);
    expect((triggers[1].source as ScheduleSource).repeat, ScheduleRepeat.off);
    expect(triggers[1].tempChatTtl, isNull);
    expect(triggers[2].source, isA<TimerSource>());
    expect(triggers[2].tempChatTtl, TempChatTtl.hours24);
    for (final entry in entries) {
      expect((entry as Map).keys, isNot(contains("temporary")));
    }
  });

  test("files in today's shape are left byte for byte", () async {
    final app = seed("settings.json", {"approveMode": "ask"});
    final triggers = seed("reminders.json", [
      {
        "id": "x",
        "source": {"kind": "timer", "seconds": 60},
      },
    ]);
    final appBefore = app.readAsStringSync();
    final triggersBefore = triggers.readAsStringSync();

    await migrate();

    expect(app.readAsStringSync(), appBefore);
    expect(triggers.readAsStringSync(), triggersBefore);
  });
}
