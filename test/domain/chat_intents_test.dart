import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/builtin_project.dart";
import "package:agent_chat/domain/chat_intents.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:agent_chat/domain/intent_action.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/turn_sender.dart";

import "../fakes.dart";

class _Turns implements TurnControl {
  TurnStatus status = TurnStatus.idle;
  final stopped = <String>[];

  @override
  TurnStatus statusOf(String chatId) => status;

  @override
  Future<bool> stop(String chatId) async {
    if (status == TurnStatus.idle) return false;
    stopped.add(chatId);
    return true;
  }
}

class _Editor implements ChatEditor {
  final calls = <String>[];

  @override
  Future<void> setPinned(ChatState chat, bool pinned) async =>
      calls.add("pin ${chat.id} $pinned");

  @override
  Future<void> retitle(ChatState chat, String title) async =>
      calls.add("retitle ${chat.id} $title");

  @override
  Future<void> move(ChatState chat, String? project) async =>
      calls.add("move ${chat.id} $project");

  @override
  Future<void> delete(ChatState chat) async => calls.add("delete ${chat.id}");
}

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
  late _Turns turns;
  late _Editor editor;
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
    turns = _Turns();
    editor = _Editor();
    notSetUp = {};
    listChanges = 0;
    registry = IntentRegistry(
      ChatIntentAction.over(
        ChatIntents(
          repo: repo,
          config: config,
          sender: driver,
          turns: turns,
          presenter: presenter,
          editor: editor,
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

  group("reply", () {
    Future<String> said() async {
      final id = await chatTitled("talk");
      await repo.append(
        id,
        recordsOf([
          userMessage("What is two and two?"),
          Message(
            id: "a1",
            role: MessageRole.assistant,
            createdAt: DateTime(2026),
            parts: const [MessagePart.text(text: "Four.")],
          ),
        ]),
      );
      return id;
    }

    test("is the last thing the agent said", () async {
      expect(await perform("reply", {"chat": await said()}), "Four.");
    });

    test("whole, is the conversation in order, each side named", () async {
      expect(
        await perform("reply", {"chat": await said(), "whole": true}),
        "You:\nWhat is two and two?\n\nEntoli:\nFour.",
      );
    });
  });

  group("a turn from outside", () {
    test("its status is the turn control's", () async {
      final id = await chatTitled("busy");
      turns.status = TurnStatus.waitingForApproval;

      expect(await perform("turnStatus", {"chat": id}), "waitingForApproval");
    });

    test("stopping one that is not running is refused", () async {
      final id = await chatTitled("quiet");

      expect(await refusal("stopTurn", {"chat": id}), contains("No turn"));

      turns.status = TurnStatus.running;
      await perform("stopTurn", {"chat": id});
      expect(turns.stopped, [id]);
    });
  });

  group("addFiles", () {
    String staged(String text) {
      final file = File("${tmp.path}/staged-${text.hashCode}")
        ..writeAsStringSync(text);
      return file.path;
    }

    test("moves a staged file into the chat's own workspace", () async {
      final id = await chatTitled("files");

      await perform("addFiles", {
        "chat": id,
        "files": [
          {"name": "notes/today.md", "staged": staged("hello")},
        ],
      });

      final landed = File("${config.workspaceDir(id)}/notes/today.md");
      expect(landed.readAsStringSync(), "hello");
    });

    test("with no chat, into the project's shared workspace", () async {
      await perform("addFiles", {
        "files": [
          {"name": "../escape.txt", "staged": staged("x")},
        ],
      });

      // The name came from outside, so it cannot climb out.
      expect(
        File("${config.projectWorkspaceDir()}/escape.txt").existsSync(),
        isTrue,
      );
    });

    test("refuses a project whose chats share no workspace", () async {
      expect(
        await refusal("addFiles", {
          "project": const AnonymousProject().dir,
          "files": [
            {"name": "a", "staged": staged("a")},
          ],
        }),
        contains("no workspace"),
      );
    });
  });

  test("artifacts is empty for a chat that published none", () async {
    expect(await perform("artifacts", {"chat": await chatTitled("x")}), []);
  });

  group("managing a chat", () {
    test("each edit goes to the editor with the chat", () async {
      final id = await chatTitled("old");
      await repo.createProject("work");

      await perform("renameChat", {"chat": id, "title": " new "});
      await perform("pinChat", {"chat": id, "pinned": false});
      await perform("moveChat", {"chat": id, "project": "work"});
      await perform("deleteChat", {"chat": id});

      expect(editor.calls, [
        "retitle $id new",
        "pin $id false",
        "move $id work",
        "delete $id",
      ]);
    });

    test("a move to a project that is not there is refused", () async {
      final id = await chatTitled("x");
      expect(
        await refusal("moveChat", {"chat": id, "project": "nowhere"}),
        contains("nowhere"),
      );
      expect(editor.calls, isEmpty);
    });

    test("an id that climbs out of chats/ is no chat", () async {
      expect(
        await refusal("renameChat", {"chat": "../x", "title": "t"}),
        contains("no longer exists"),
      );
    });
  });

  group("createProject", () {
    test("makes what was typed safe, and returns it", () async {
      final made = await perform("createProject", {"name": "My work!"}) as Map;

      expect(made["id"], "My-work");
      expect(await repo.listProjects(), contains("My-work"));
    });

    test("refuses a name already taken", () async {
      await repo.createProject("work");
      expect(
        await refusal("createProject", {"name": "work"}),
        contains("already"),
      );
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
