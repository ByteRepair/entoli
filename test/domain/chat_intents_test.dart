import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_intents.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/intent_action.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/turn_sender.dart";

import "../fakes.dart";

class _Presenter implements ChatPresenter {
  final shown = <ChatState>[];

  @override
  void show(ChatState chat) => shown.add(chat);
}

void main() {
  late Directory tmp;
  late AppConfig config;
  late ChatRepository repo;
  late FakeTurnSender driver;
  late _Presenter presenter;
  late Set<String?> notSetUp;
  late int listChanges;
  late IntentRegistry registry;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("chat_intents_test_");
    config = AppConfig.forDirectory(tmp.path);
    repo = ChatRepository(
      FileChatStore(config),
      FakeBackend(),
      () => AppSettings(defaultProviderId: "anthropic", defaultModelId: "m"),
      config,
    );
    driver = FakeTurnSender();
    presenter = _Presenter();
    notSetUp = {};
    listChanges = 0;
    registry = IntentRegistry(
      ChatIntentAction.over(
        ChatIntents(
          repo: repo,
          sender: driver,
          presenter: presenter,
          isSetUp: (project) => !notSetUp.contains(project),
          onListChanged: () => listChanges++,
        ),
      ),
    );
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<Object?> perform(String id, [Map<String, Object?> args = const {}]) =>
      registry.perform(id, IntentArgs(args));

  Future<String> refusal(String id, [Map<String, Object?> args = const {}]) =>
      perform(id, args).then<String>(
        (_) => fail("$id was not refused"),
        onError: (Object e) => (e as IntentRefused).reason,
      );

  Future<String> chatTitled(String title, {String? project}) async {
    final chat = await repo.createChat(title: title, project: project);
    return chat.state.id;
  }

  group("findChats", () {
    test("matches titles the way the sidebar does, newest first", () async {
      final older = await chatTitled("Shell scripts");
      final newer = await chatTitled("More shell");
      await chatTitled("Groceries");

      final found = await perform("findChats", {"query": " SHELL "}) as List;

      expect([for (final c in found) (c as Map)["id"]], [newer, older]);
    });

    test("keeps to a named project, the default's id included", () async {
      await repo.createProject("work");
      final inDefault = await chatTitled("a");
      await chatTitled("b", project: "work");

      final found = await perform("findChats", {"project": "default"}) as List;

      expect([for (final c in found) (c as Map)["id"]], [inDefault]);
    });

    test("refuses a project that is not there", () async {
      expect(
        await refusal("findChats", {"project": "nowhere"}),
        contains("nowhere"),
      );
    });
  });

  test(
    "chats reads back the ids a shortcut kept, skipping gone ones",
    () async {
      final kept = await chatTitled("kept");

      final read =
          await perform("chats", {
                "ids": [kept, "gone"],
              })
              as List;

      expect(read, hasLength(1));
      expect((read.single as Map)["project"], {
        "id": "default",
        "label": "Default",
      });
    },
  );

  test("newChat makes a chat in the project and tells the sidebar", () async {
    await repo.createProject("work");

    final made = await perform("newChat", {"project": "work"}) as Map;

    final stored = (await repo.listChats()).single;
    expect(made["id"], stored.id);
    expect(stored.project, "work");
    expect(listChanges, 1);
  });

  test("openChat shows the chat, and refuses one that is gone", () async {
    final id = await chatTitled("here");

    await perform("openChat", {"chat": id});

    expect(presenter.shown.single.id, id);
    expect(await refusal("openChat", {"chat": "gone"}), contains("no longer"));
  });

  group("ask", () {
    test("with no chat, starts one and returns the reply", () async {
      driver.snippet = "Hello back";

      final result = await perform("ask", {"prompt": "Hello"}) as Map;

      final chatId = (result["chat"] as Map)["id"];
      expect(driver.calls.single, (chatId: chatId, prompt: "Hello"));
      expect(result["reply"], "Hello back");
      expect(result["outcome"], TurnOutcome.done.name);
    });

    test("says it into the chat named", () async {
      final id = await chatTitled("existing");

      await perform("ask", {"prompt": "More", "chat": id});

      expect(driver.calls.single.chatId, id);
      expect(await repo.listChats(), hasLength(1));
    });

    test("not waiting returns at once, the turn still running", () async {
      final result =
          await perform("ask", {"prompt": "Later", "wait": false}) as Map;

      expect(result["outcome"], "running");
      expect(result["reply"], "");
    });

    test("refuses a chat and a project both", () async {
      final id = await chatTitled("x");
      expect(
        await refusal("ask", {"prompt": "p", "chat": id, "project": "default"}),
        contains("not both"),
      );
    });

    test("refuses an empty prompt", () async {
      expect(await refusal("ask", {"prompt": "  "}), contains("required"));
    });

    test("refuses a project still waiting on its setup", () async {
      notSetUp.add(null);
      expect(await refusal("ask", {"prompt": "p"}), contains("setting up"));
      expect(driver.calls, isEmpty);
    });
  });

  group("the registry", () {
    test("refuses an id it does not know", () async {
      expect(await refusal("later.thing"), contains("Update it"));
    });

    test("refuses a mistyped argument rather than throwing a cast", () async {
      expect(
        await refusal("findChats", {"limit": "ten"}),
        contains("wrong kind"),
      );
    });
  });
}
