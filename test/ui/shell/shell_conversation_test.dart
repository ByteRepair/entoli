import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/app/chat_controller.dart";
import "package:agent_chat/app/transcript/transcript.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/room/room_state.dart";
import "package:agent_chat/ui/shell/shell_answers.dart";
import "package:agent_chat/ui/shell/shell_conversation.dart";

import "../../harness.dart";
import "fake_native_transcript.dart";

/// Records what a message's actions asked of the turn.
class _Driver implements TurnDriver {
  final deleted = <String>[];

  @override
  Future<void> deleteThread(String messageId) async => deleted.add(messageId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Message _said(String id, MessageRole role, List<MessagePart> parts) =>
    Message(id: id, role: role, createdAt: DateTime(2026), parts: parts);

void main() {
  late FakeNativeTranscript native;
  late TestApp app;

  setUp(() {
    native = FakeNativeTranscript.install();
    app = TestApp.create();
    addTearDown(app.dispose);
  });

  Chat chatOf(List<Message> messages) =>
      Chat(state: makeState("c"), messages: messages);

  Future<void> pump(
    WidgetTester tester,
    Chat chat, {
    TurnDriver? driver,
    bool running = false,
  }) {
    final view = ChatViewState(chat: chat, isRunning: running);
    return app.pump(
      tester,
      ShellConversation(
        chatId: "c",
        transcript: Transcript.of("c", chat),
        view: view,
        source: Provider((_) => view),
        driver: driver,
      ),
    );
  }

  final prompt = _said("u", MessageRole.user, [
    const MessagePart.text(text: "List the files."),
  ]);

  testWidgets("every row goes out once, and then only the one that changed", (
    tester,
  ) async {
    Message reply(String text) =>
        _said("r", MessageRole.assistant, [MessagePart.text(text: text)]);
    await pump(tester, chatOf([prompt, reply("Two")]));
    final first = native.conversations.last;
    expect(first.order, ["message:u", "message:r"]);
    expect(first.changed.map((r) => r.key), ["message:u", "message:r"]);
    final said = first.changed.last.message!.blocks.single.said.single;
    expect(said.blocks.single.inlines.single.text, "Two");

    await pump(tester, chatOf([prompt, reply("Two files.")]));
    expect(native.conversations.last.changed.map((r) => r.key), ["message:r"]);
  });

  testWidgets("a reply's activities go out as the core's nodes, and one "
      "opened is its detail", (tester) async {
    const call = ToolCall(
      id: "c1",
      name: "bash",
      argumentsJson: '{"command":"ls"}',
    );
    final reply = _said("r", MessageRole.assistant, const [
      MessagePart.toolCall(toolCall: call),
      MessagePart.toolResult(
        result: ToolResult(callId: "c1", returnCode: 0, output: "a\nb"),
      ),
      MessagePart.text(text: "Two files."),
    ]);
    await pump(tester, chatOf([prompt, reply]));
    final blocks = native.conversations.last.changed.last.message!.blocks;
    expect(blocks.first.kind, BlockKind.activity);
    final node = blocks.first.nodes.single;
    expect(node.text, "Used tool: bash");

    final surface =
        tester.state(find.byType(ShellConversation)) as TranscriptIntents;
    surface.open(node.id);
    await tester.pump();
    final detail = native.details.last;
    expect(detail.present, isTrue);
    expect(detail.title, "bash");
    expect(detail.command, "ls");
    expect(detail.sections.map((s) => s.label), contains("Output"));

    surface.closeDetail();
    await tester.pump();
    expect(native.details.last.present, isFalse);
  });

  testWidgets("a message's actions are the core's, and act through the turn", (
    tester,
  ) async {
    final driver = _Driver();
    await pump(tester, chatOf([prompt]), driver: driver);
    final row = native.conversations.last.changed.single;
    expect(row.message!.actions.delete, isTrue);
    expect(row.message!.actions.edit, isTrue);

    final surface =
        tester.state(find.byType(ShellConversation)) as TranscriptIntents;
    surface.act(row.key, MessageAction.delete);
    await tester.pump();
    expect(driver.deleted, ["u"]);

    // While a turn runs, nothing is offered that the controller refuses.
    await pump(tester, chatOf([prompt]), driver: driver, running: true);
    final actions = native.conversations.last.changed.single.message!.actions;
    expect(actions.delete, isFalse);
  });

  testWidgets("gone, it takes the conversation back", (tester) async {
    await pump(tester, chatOf([prompt]));
    await app.pump(tester, const SizedBox());
    expect(native.conversations.last.chatId, isNull);
    expect(app.container.read(shellAnswersProvider).transcript.owner, isNull);
  });
}
