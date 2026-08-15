import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/local/memory_chat_store.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";

import "../harness.dart";

void main() {
  late MemoryChatStore store;

  setUp(() => store = MemoryChatStore());

  Chat chatOf(String id, {String? project}) => Chat(
        state: makeState(id, project: project),
        messages: [
          Message(
            id: "m1",
            role: MessageRole.user,
            createdAt: DateTime.utc(2026, 1, 1),
            parts: [const MessagePart.text(text: "hello")],
          ),
        ],
      );

  test("save round-trips a chat", () async {
    await store.save(chatOf("c1"));

    final chat = await store.load("c1");
    expect(chat.state.title, "Test chat c1");
    expect(chat.messages.single.parts.single, const MessagePart.text(text: "hello"));
  });

  test("load throws for a chat nothing was saved under", () {
    expect(store.load("nope"), throwsStateError);
  });

  test("list is newest first and stamps each chat with its project", () async {
    await store.createProject("work");
    await store.save(Chat(state: makeState("old", day: 1)));
    await store.save(Chat(state: makeState("new", day: 3)));
    await store.save(chatOf("scoped", project: "work"));

    final listed = await store.list();
    expect(listed.map((s) => s.id), ["new", "scoped", "old"]);
    expect(listed.firstWhere((s) => s.id == "scoped").project, "work");
    expect(await store.projectOf("scoped"), "work");
    expect(await store.projectOf("old"), isNull);
  });

  test("saveState keeps the messages already held", () async {
    await store.save(chatOf("c1"));
    await store.saveState(makeState("c1").copyWith(title: "Renamed"));

    final chat = await store.load("c1");
    expect(chat.state.title, "Renamed");
    expect(chat.messages, hasLength(1));
  });

  test("where a chat already is wins over what a held copy says", () async {
    await store.createProject("work");
    await store.save(chatOf("c1", project: "work"));
    // A copy from before the chat was in a project, saved late.
    await store.saveState(makeState("c1"));

    expect(await store.projectOf("c1"), "work");
  });

  test("moveChat moves a chat between projects", () async {
    await store.createProject("work");
    await store.save(chatOf("c1"));
    await store.moveChat("c1", "work");
    expect((await store.load("c1")).state.project, "work");

    await store.moveChat("c1", null);
    expect((await store.load("c1")).state.project, isNull);
  });

  test("deleteProject takes its chats with it", () async {
    await store.createProject("work");
    await store.save(chatOf("kept"));
    await store.save(chatOf("gone", project: "work"));

    await store.deleteProject("work");

    expect(await store.listProjects(), isEmpty);
    expect((await store.list()).map((s) => s.id), ["kept"]);
  });

  test("resources are read back per chat, and deleted with it", () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    await store.save(chatOf("c1"));
    final resource = await store.saveResource("c1", "shot.png", bytes);

    expect(resource, endsWith("-shot.png"));
    expect(await store.readResource("c1", resource), bytes);
    expect(await store.readResource("c2", resource), isNull);

    await store.delete("c1");
    expect(await store.readResource("c1", resource), isNull);
  });

  test("meta is copied in and out, not shared with the caller", () async {
    final meta = ChatMeta(model: "qwen-2.5", provider: "ollama");
    await store.saveMeta("c1", meta);
    meta.model = "changed";

    final loaded = await store.loadMeta("c1");
    expect(loaded.model, "qwen-2.5");
    loaded.approveMode = ApproveMode.never;
    expect((await store.loadMeta("c1")).approveMode, isNull);
  });

  test("a chat nothing was saved for has default meta", () async {
    expect((await store.loadMeta("c1")).model, isNull);
  });
}
