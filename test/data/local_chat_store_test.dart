import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/local_chat_store.dart";
import "package:agent_chat/domain/models.dart";

import "../harness.dart";

void main() {
  late AppConfig config;
  late LocalChatStore store;

  setUp(() {
    config = tempConfig();
    store = LocalChatStore(config);
  });

  ChatState makeState(String id, {String? model}) => ChatState(
        id: id,
        title: "Test chat $id",
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
        backend: BackendKind.opencode,
        model: model,
      );

  test("save writes state.json and conv.json", () async {
    final state = makeState("c1");
    final messages = [
      Message(
        id: "m1",
        role: MessageRole.user,
        createdAt: DateTime.utc(2026, 1, 1),
        parts: [const MessagePart.text(text: "hello")],
      ),
    ];
    await store.save(Chat(state: state, messages: messages));

    expect(config.stateFile("c1").existsSync(), isTrue);
    expect(config.convFile("c1").existsSync(), isTrue);
    expect(config.resourcesDir("c1").existsSync(), isTrue);
    expect(config.workspaceDir("c1").existsSync(), isTrue);

    final stateJson = jsonDecode(config.stateFile("c1").readAsStringSync()) as Map<String, dynamic>;
    expect(stateJson["id"], "c1");
    expect(stateJson["title"], "Test chat c1");
    expect(stateJson["backend"], "opencode");

    final convJson = jsonDecode(config.convFile("c1").readAsStringSync()) as Map<String, dynamic>;
    final msgs = convJson["messages"] as List;
    expect(msgs.length, 1);
    expect((msgs[0] as Map<String, dynamic>)["role"], "user");
  });

  test("load reads back a saved chat", () async {
    final state = makeState("c2", model: "anthropic/claude-sonnet-4-5-20250929");
    final messages = [
      Message(
        id: "m1",
        role: MessageRole.user,
        createdAt: DateTime.utc(2026, 1, 1),
        parts: [const MessagePart.text(text: "hi")],
      ),
      Message(
        id: "m2",
        role: MessageRole.assistant,
        createdAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
        parts: [const MessagePart.text(text: "hello back")],
      ),
    ];
    await store.save(Chat(state: state, messages: messages));

    final loaded = await store.load("c2");
    expect(loaded.state.id, "c2");
    expect(loaded.state.model, "anthropic/claude-sonnet-4-5-20250929");
    expect(loaded.messages.length, 2);
    expect(loaded.messages[0].role, MessageRole.user);
    expect(loaded.messages[1].role, MessageRole.assistant);
    expect(
      (loaded.messages[0].parts.first as TextPart).text,
      "hi",
    );
  });

  test("list returns summaries sorted by updatedAt desc", () async {
    final older = ChatState(
      id: "older",
      title: "Older",
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      backend: BackendKind.opencode,
    );
    final newer = ChatState(
      id: "newer",
      title: "Newer",
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 6, 1),
      backend: BackendKind.opencode,
    );
    await store.save(Chat(state: older, messages: const []));
    await store.save(Chat(state: newer, messages: const []));

    final summaries = await store.list();
    expect(summaries.length, 2);
    expect(summaries.first.id, "newer");
    expect(summaries.last.id, "older");
  });

  test("list skips dirs without state.json", () async {
    Directory(p.join(config.chatsDir.path, "junk")).createSync();
    await store.save(Chat(state: makeState("real"), messages: const []));

    final summaries = await store.list();
    expect(summaries.length, 1);
    expect(summaries.first.id, "real");
  });

  test("list handles empty chats dir", () async {
    final summaries = await store.list();
    expect(summaries, isEmpty);
  });

  test("delete removes the chat directory", () async {
    await store.save(Chat(state: makeState("c3"), messages: const []));
    expect(config.chatDir("c3").existsSync(), isTrue);

    await store.delete("c3");
    expect(config.chatDir("c3").existsSync(), isFalse);
  });

  test("saveResource writes bytes under resources/ and reads them back", () async {
    await store.save(Chat(state: makeState("c4"), messages: const []));

    final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
    final resource = await store.saveResource("c4", "test.bin", bytes);
    expect(resource, endsWith("test.bin"));
    expect(File(p.join(config.resourcesDir("c4").path, resource)).readAsBytesSync(), bytes);
    expect(await store.readResource("c4", resource), bytes);
  });

  test("saveResource sanitizes unsafe filename characters", () async {
    await store.save(Chat(state: makeState("c5"), messages: const []));

    final resource = await store.saveResource("c5", "../bad name.txt", Uint8List(0));
    expect(resource, contains("bad_name.txt"));
    expect(resource, isNot(contains("..")));
  });

  // Two turns attaching the same filename must not overwrite each other.
  test("saveResource gives each attachment its own name", () async {
    await store.save(Chat(state: makeState("c5b"), messages: const []));

    final first = await store.saveResource("c5b", "shot.png", Uint8List.fromList([1]));
    final second = await store.saveResource("c5b", "shot.png", Uint8List.fromList([2]));

    expect(first, isNot(second));
    expect(await store.readResource("c5b", first), [1]);
    expect(await store.readResource("c5b", second), [2]);
  });

  test("readResource is null for a resource that is not there", () async {
    await store.save(Chat(state: makeState("c5c"), messages: const []));

    expect(await store.readResource("c5c", "missing.png"), isNull);
  });

  test("round-trips tool call and tool result parts", () async {
    final state = makeState("c6");
    final messages = [
      Message(
        id: "m1",
        role: MessageRole.assistant,
        createdAt: DateTime.utc(2026, 1, 1),
        parts: [
          MessagePart.toolCall(
            toolCall: const ToolCall(id: "tc1", name: "bash", argumentsText: "ls -la"),
          ),
        ],
      ),
      Message(
        id: "m2",
        role: MessageRole.tool,
        createdAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
        parts: [
          MessagePart.toolResult(
            result: const ToolResult(callId: "tc1", returnCode: 0, output: "total 0"),
          ),
        ],
      ),
    ];
    await store.save(Chat(state: state, messages: messages));
    final loaded = await store.load("c6");
    expect(loaded.messages[0].parts.first, isA<ToolCallPart>());
    expect((loaded.messages[0].parts.first as ToolCallPart).toolCall.name, "bash");
    expect(loaded.messages[1].parts.first, isA<ToolResultPart>());
    expect((loaded.messages[1].parts.first as ToolResultPart).result.output, "total 0");
  });
}