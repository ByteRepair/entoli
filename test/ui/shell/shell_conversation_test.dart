import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/widgets.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/app/chat_controller.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/selection.dart";
import "package:agent_chat/ui/shell/shell_answers.dart";

import "../../harness.dart";
import "fake_native_shell.dart";
import "fake_native_transcript.dart";

Message _said(String id, MessageRole role, List<MessagePart> parts) =>
    Message(id: id, role: role, createdAt: DateTime(2026), parts: parts);

/// The open chat as the native shell publishes it: from the app's state,
/// with no chat page building.
void main() {
  late FakeNativeTranscript native;
  late FakeNativeShell shell;
  late TestApp app;

  setUp(() {
    native = FakeNativeTranscript.install();
    shell = FakeNativeShell.install();
    app = TestApp.create();
    addTearDown(app.dispose);
  });

  final prompt = _said("u", MessageRole.user, const [
    MessagePart.text(text: "List the files."),
  ]);

  /// [messages] in a chat, open, the shell's publisher up.
  Future<String> open(WidgetTester tester, List<Message> messages) async {
    final id = await io(tester, () async {
      final chat = await app.repo.createChat(title: "files");
      await app.writeChat(chat.copyWith(messages: messages));
      return chat.state.id;
    });
    await app.pump(tester, const ShellChatHost(child: SizedBox()));
    app.container.read(selectedChatIdProvider.notifier).select(id);
    await settleShell(tester);
    return id;
  }

  TranscriptIntents intents() =>
      app.container.read(shellAnswersProvider).transcript.owner!;

  testWidgets("a chat goes out row by row, and its bar and composer with it, "
      "with no page building", (tester) async {
    final reply = _said("r", MessageRole.assistant, const [
      MessagePart.text(text: "Two"),
    ]);
    await open(tester, [prompt, reply]);
    final first = native.conversations.last;
    expect(first.order, ["message:u", "message:r"]);
    expect(native.rows.keys, containsAll(["message:u", "message:r"]));
    final said = native.rows["message:r"]!.message!.blocks.single.said.single;
    expect(said.blocks.single.inlines.single.text, "Two");
    expect(shell.lastChatBar?.title, "files");
    expect(shell.lastComposer?.present, isTrue);
  });

  testWidgets("a change no row shows resends no row, and the bar takes it", (
    tester,
  ) async {
    final id = await open(tester, [prompt]);
    final before = native.conversations.length;
    final controller = app.container.read(chatControllerProvider(id).notifier);
    final state = app.container.read(chatControllerProvider(id)).chat!.state;
    controller.applyState(state.copyWith(title: "renamed"));
    await settleShell(tester);
    expect(shell.lastChatBar?.title, "renamed");
    expect(native.conversations.length, greaterThan(before));
    expect(native.conversations.skip(before).expand((c) => c.changed), isEmpty);
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
    await open(tester, [prompt, reply]);
    final node = native.rows["message:r"]!.message!.blocks.first.nodes.single;
    expect(node.text, "Used tool: bash");

    intents().open(node.id);
    await settleShell(tester);
    final detail = native.details.last;
    expect(detail.present, isTrue);
    expect(detail.title, "bash");
    expect(detail.command, "ls");

    intents().closeDetail();
    await settleShell(tester);
    expect(native.details.last.present, isFalse);
  });

  testWidgets("a message's actions act through the chat's turn", (
    tester,
  ) async {
    final reply = _said("r", MessageRole.assistant, const [
      MessagePart.text(text: "Two files."),
    ]);
    await open(tester, [prompt, reply]);
    expect(native.rows["message:u"]!.message!.actions.delete, isTrue);

    intents().act("message:u", MessageAction.delete);
    await settleShell(tester);
    expect(native.conversations.last.order, isEmpty);
  });

  testWidgets("a passage answered goes into the composer as a quote", (
    tester,
  ) async {
    final reply = _said("r", MessageRole.assistant, const [
      MessagePart.text(text: "Two files."),
    ]).copyWith(author: "@athena");
    await open(tester, [prompt, reply]);
    intents().reply("message:r", "Two");
    await settleShell(tester);
    expect(shell.lastComposer?.cards.values.single.body, contains("Two"));
  });

  // Byte Repair requires setup: until it is done the bar stands where the
  // composer would, and nothing can be sent.
  testWidgets("a chat in a project still to be set up has the bar in the "
      "composer's place", (tester) async {
    final chat = await io(tester, () => app.seedChat(project: "byte-repair"));
    await app.pump(tester, const ShellChatHost(child: SizedBox()));
    app.container.read(selectedChatIdProvider.notifier).select(chat.state.id);
    await settleShell(tester);
    expect(shell.lastFoot?.bar, FootBar.needsSetup);
    expect(shell.lastComposer?.present ?? false, isFalse);
  });

  testWidgets("a chat of this device's has no device banner and no bar", (
    tester,
  ) async {
    await open(tester, [prompt]);
    expect(shell.lastFoot?.device, isNull);
    expect(shell.lastFoot?.bar, FootBar.none);
    expect(shell.lastFoot?.upload, isNull);
  });

  testWidgets("closing the chat takes it back", (tester) async {
    await open(tester, [prompt]);
    app.container.read(selectedChatIdProvider.notifier).select(null);
    await settleShell(tester);
    expect(native.conversations.last.chatId, isNull);
    expect(app.container.read(shellAnswersProvider).transcript.owner, isNull);
  });
}
