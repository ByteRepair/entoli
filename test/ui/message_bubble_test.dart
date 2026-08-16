import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";

import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/widgets/message_bubble.dart";

import "../fakes.dart";
import "../harness.dart";

Message _message(MessageRole role, List<MessagePart> parts) =>
    Message(id: "m1", role: role, createdAt: DateTime(2026), parts: parts);

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<void> pump(
    WidgetTester tester,
    Message message, {
    String chatId = "chat-1",
    bool isWaiting = false,
    String? waitingNotice,
    ValueChanged<String>? onEdit,
    VoidCallback? onRegenerate,
    ValueChanged<String>? onTapLink,
  }) =>
      app.pump(
        tester,
        Scaffold(
          body: MessageBubble(
            chatId: chatId,
            message: message,
            isWaiting: isWaiting,
            waitingNotice: waitingNotice,
            onEdit: onEdit,
            onRegenerate: onRegenerate,
            onTapLink: onTapLink,
          ),
        ),
        settle: !isWaiting,
      );

  /// Touch the message, which is how the actions under it are uncovered where
  /// there is no pointer to hover with.
  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.tap(target, warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  /// How visible the row of action icons currently is.
  double actionsOpacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

  /// Open the drawer behind a thinking label, which every caller times at 12s.
  Future<void> openThinking(WidgetTester tester) async {
    await tester.tap(find.text("Thought for 12 seconds"));
    await tester.pumpAndSettle();
  }

  testWidgets("an error part renders in the theme's error colour", (tester) async {
    await pump(tester, _message(MessageRole.assistant, [const ErrorPart(message: "usage limit reached")]));

    final rendered = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .firstWhere((t) => t.data!.contains("usage limit reached"));
    final context = tester.element(find.byType(MessageBubble));
    expect(rendered.style?.color, Theme.of(context).colorScheme.error);
  });

  testWidgets("an empty reply spins while the turn is running", (tester) async {
    await pump(tester, _message(MessageRole.assistant, const []), isWaiting: true);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets("the spinner gives way to the first text", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [const TextPart(text: "Hel")]),
      isWaiting: true,
    );

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text("Hel"), findsOneWidget);
  });

  testWidgets("a tool call with no text yet still spins", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [
        const ToolCallPart(toolCall: ToolCall(id: "1", name: "bash")),
      ]),
      isWaiting: true,
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets("a retry notice sits beside the spinner in red", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const []),
      isWaiting: true,
      waitingNotice: "Attempt 1 failed: you have reached your session usage limit",
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final notice = tester.widget<Text>(find.textContaining("usage limit"));
    final context = tester.element(find.byType(MessageBubble));
    expect(notice.style?.color, Theme.of(context).colorScheme.error);
  });

  testWidgets("a finished empty reply does not spin", (tester) async {
    await pump(tester, _message(MessageRole.assistant, const []));

    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets("an errored reply shows the error, not a spinner", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [const ErrorPart(message: "usage limit reached")]),
      isWaiting: true,
    );

    expect(find.textContaining("usage limit reached"), findsOneWidget);
  });

  testWidgets("a failed reply offers Retry without hunting for the menu", (tester) async {
    var fired = 0;
    await pump(
      tester,
      _message(MessageRole.assistant, [const ErrorPart(message: "usage limit reached")]),
      onRegenerate: () => fired++,
    );

    await tester.tap(find.text("Retry"));
    await tester.pumpAndSettle();

    expect(fired, 1);
  });

  testWidgets("a reply still running offers no Retry", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [const ErrorPart(message: "rate limited")]),
      isWaiting: true,
      onRegenerate: () {},
    );

    expect(find.text("Retry"), findsNothing);
  });

  testWidgets("a healthy reply offers no Retry", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [const TextPart(text: "all good")]),
      onRegenerate: () {},
    );

    expect(find.text("Retry"), findsNothing);
  });

  testWidgets("thinking reads as a label, and stays out of the bubble", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [
        ReasoningPart(text: "17*23 = 391", durationMs: 12000),
        TextPart(text: "391"),
      ]),
    );

    expect(find.text("Thought for 12 seconds"), findsOneWidget);
    expect(find.text("391"), findsOneWidget);
    expect(find.text("17*23 = 391"), findsNothing);
  });

  testWidgets("the label opens the thinking in a drawer", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [
        ReasoningPart(text: "17*23 = 391", durationMs: 12000),
        TextPart(text: "391"),
      ]),
    );

    await openThinking(tester);

    expect(find.text("17*23 = 391"), findsOneWidget);
  });

  testWidgets("the back key closes the drawer rather than the app", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [
        ReasoningPart(text: "17*23 = 391", durationMs: 12000),
      ]),
    );
    await openThinking(tester);

    expect(await pressBack(tester), isTrue);

    expect(find.text("17*23 = 391"), findsNothing);
  });

  // Long output fills the screen rather than stopping at a fraction of it.
  testWidgets("the drawer grows to what is in it", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [
        ReasoningPart(text: List.filled(400, "thinking").join("\n"), durationMs: 12000),
      ]),
    );
    await openThinking(tester);

    final screen = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(tester.getSize(find.byType(BottomSheet)).height, screen);
  });

  testWidgets("a long think is counted in minutes", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [ReasoningPart(text: "...", durationMs: 125000)]),
    );

    expect(find.text("Thought for 2 minutes 5 seconds"), findsOneWidget);
  });

  testWidgets("thinking still being written says so", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [ReasoningPart(text: "hmm")]),
      isWaiting: true,
    );

    expect(find.text("Thinking…"), findsOneWidget);
  });

  // Nothing timed it: an older conversation, or a turn that was aborted.
  testWidgets("an untimed block is still worth opening", (tester) async {
    await pump(tester, _message(MessageRole.assistant, const [ReasoningPart(text: "hmm")]));

    expect(find.text("View thinking"), findsOneWidget);
  });

  testWidgets("a tool run is one label, with the detail behind it", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [
        ToolCallPart(toolCall: ToolCall(id: "c1", name: "bash", argumentsText: "pwd")),
        ToolResultPart(result: ToolResult(callId: "c1", returnCode: 0, output: "/workspace")),
        TextPart(text: "you are in /workspace"),
      ]),
    );

    expect(find.text("Used tool: bash"), findsOneWidget);
    expect(find.text("/workspace"), findsNothing);

    await tester.tap(find.text("Used tool: bash"));
    await tester.pumpAndSettle();

    expect(find.text("pwd"), findsOneWidget);
    expect(find.text("/workspace"), findsOneWidget);
  });

  testWidgets("an answered question reads as the question, not as a tool run",
      (tester) async {
    const asked = [
      AskQuestion(
        question: "Which database?",
        options: [AskOption(label: "Postgres")],
      ),
    ];
    await pump(
      tester,
      _message(MessageRole.assistant, [
        ToolCallPart(
          toolCall: ToolCall(
            id: "a1",
            name: askToolName,
            argumentsJson: jsonEncode({
              "questions": [
                {
                  "question": "Which database?",
                  "options": [
                    {"label": "Postgres"},
                  ],
                },
              ],
            }),
          ),
        ),
        ToolResultPart(
          result: ToolResult(
            callId: "a1",
            returnCode: 0,
            output: askAnswers(asked, ["Postgres"]),
          ),
        ),
      ]),
    );

    expect(find.text("Used tool: $askToolName"), findsNothing);
    expect(find.text("Which database?"), findsOneWidget);

    await tester.tap(find.text("Which database?"));
    await tester.pumpAndSettle();

    expect(find.text("Postgres"), findsOneWidget);
  });

  // Named ask_user, but the model got the arguments wrong: the label has to be
  // the failed run it is, not an empty question.
  testWidgets("a question with nothing askable in it falls back to a tool label",
      (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [
        ToolCallPart(toolCall: ToolCall(id: "a1", name: askToolName, argumentsJson: "{oops")),
        ToolResultPart(
          result: ToolResult(
            callId: "a1",
            returnCode: -1,
            output: "",
            exceptionInfo: "Every question needs at least one option",
          ),
        ),
      ]),
    );

    expect(find.text("Used tool: $askToolName"), findsOneWidget);

    await tester.tap(find.text("Used tool: $askToolName"));
    await tester.pumpAndSettle();

    expect(find.text("Every question needs at least one option"), findsOneWidget);
  });

  testWidgets("a tool still running says so", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [
        ToolCallPart(toolCall: ToolCall(id: "c1", name: "bash", argumentsText: "sleep 60")),
      ]),
      isWaiting: true,
    );

    expect(find.text("Using tool: bash"), findsOneWidget);
  });

  testWidgets("a failed tool run is drawn in the error colour", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [
        ToolCallPart(toolCall: ToolCall(id: "c1", name: "bash", argumentsText: "nope")),
        ToolResultPart(
          result: ToolResult(callId: "c1", returnCode: 1, output: "", exceptionInfo: "not found"),
        ),
      ]),
    );

    final context = tester.element(find.byType(MessageBubble));
    final label = tester.widget<TextButton>(find.widgetWithText(TextButton, "Used tool: bash"));
    expect(
      label.style?.foregroundColor?.resolve({}),
      Theme.of(context).colorScheme.error,
    );
  });

  // The turn as it happened: thinking, a tool, thinking again, then the reply.
  testWidgets("labels stack above the bubble in the order they happened", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [
        ReasoningPart(text: "how do I check?", durationMs: 4000),
        ToolCallPart(toolCall: ToolCall(id: "c1", name: "bash", argumentsText: "pwd")),
        ToolResultPart(result: ToolResult(callId: "c1", returnCode: 0, output: "/workspace")),
        ReasoningPart(text: "that is the answer", durationMs: 2000),
        TextPart(text: "you are in /workspace"),
      ]),
    );

    double y(String text) => tester.getTopLeft(find.text(text)).dy;

    expect(y("Thought for 4 seconds"), lessThan(y("Used tool: bash")));
    expect(y("Used tool: bash"), lessThan(y("Thought for 2 seconds")));
    expect(y("Thought for 2 seconds"), lessThan(y("you are in /workspace")));
  });

  testWidgets("text before a tool call keeps its own bubble", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [
        TextPart(text: "let me look"),
        ToolCallPart(toolCall: ToolCall(id: "c1", name: "bash", argumentsText: "pwd")),
        ToolResultPart(result: ToolResult(callId: "c1", returnCode: 0, output: "/workspace")),
        TextPart(text: "found it"),
      ]),
    );

    double y(String text) => tester.getTopLeft(find.text(text)).dy;

    expect(y("let me look"), lessThan(y("Used tool: bash")));
    expect(y("Used tool: bash"), lessThan(y("found it")));
  });

  testWidgets("a user message offers both Edit and Regenerate", (tester) async {
    await pump(
      tester,
      _message(MessageRole.user, [const TextPart(text: "hello")]),
      onEdit: (_) {},
      onRegenerate: () {},
    );

    await reveal(tester, find.text("hello"));

    expect(find.byTooltip("Edit"), findsOneWidget);
    expect(find.byTooltip("Regenerate"), findsOneWidget);
  });

  testWidgets("an assistant message offers only Regenerate", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [const TextPart(text: "hi there")]),
      onRegenerate: () {},
    );

    await reveal(tester, find.text("hi there"));

    expect(find.byTooltip("Edit"), findsNothing);
    expect(find.byTooltip("Regenerate"), findsOneWidget);
  });

  // The row keeps its height whatever is in it, so a message does not shift
  // under the pointer the moment the icons appear.
  testWidgets("the actions are covered until the message is touched", (tester) async {
    await pump(
      tester,
      _message(MessageRole.user, [const TextPart(text: "hello")]),
      onRegenerate: () {},
    );

    final before = tester.getRect(find.byType(MessageBubble));
    expect(actionsOpacity(tester), 0);

    await reveal(tester, find.text("hello"));

    expect(actionsOpacity(tester), 1);
    expect(tester.getRect(find.byType(MessageBubble)), before);
  });

  testWidgets("touching it again covers them back up", (tester) async {
    await pump(
      tester,
      _message(MessageRole.user, [const TextPart(text: "hello")]),
      onRegenerate: () {},
    );

    await reveal(tester, find.text("hello"));
    await reveal(tester, find.text("hello"));

    expect(actionsOpacity(tester), 0);
  });

  testWidgets("Regenerate fires the callback", (tester) async {
    var fired = 0;
    await pump(
      tester,
      _message(MessageRole.user, [const TextPart(text: "hello")]),
      onRegenerate: () => fired++,
    );

    await reveal(tester, find.text("hello"));
    await tester.tap(find.byTooltip("Regenerate"));
    await tester.pumpAndSettle();

    expect(fired, 1);
  });

  testWidgets("Edit opens the text prefilled and returns what was typed", (tester) async {
    String? edited;
    await pump(
      tester,
      _message(MessageRole.user, [const TextPart(text: "helo")]),
      onEdit: (text) => edited = text,
    );

    await reveal(tester, find.text("helo"));
    await tester.tap(find.byTooltip("Edit"));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, "helo"), findsOneWidget);
    await tester.enterText(find.byType(TextField), "hello");
    await tester.tap(find.text("Send"));
    await tester.pumpAndSettle();

    expect(edited, "hello");
  });

  testWidgets("cancelling the edit resends nothing", (tester) async {
    String? edited;
    await pump(
      tester,
      _message(MessageRole.user, [const TextPart(text: "helo")]),
      onEdit: (text) => edited = text,
    );

    await reveal(tester, find.text("helo"));
    await tester.tap(find.byTooltip("Edit"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Cancel"));
    await tester.pumpAndSettle();

    expect(edited, isNull);
  });

  testWidgets("nothing is offered when neither action is", (tester) async {
    await pump(tester, _message(MessageRole.user, [const TextPart(text: "hello")]));

    await reveal(tester, find.text("hello"));

    expect(find.byTooltip("Regenerate"), findsNothing);
    expect(find.byTooltip("Edit"), findsNothing);
  });

  // A sent message holds only the resource name, so the bytes have to come
  // back off disk before the bubble can show anything.
  testWidgets("an attachment on a sent message shows what it carried", (tester) async {
    final chat = await io(tester, () => app.repo.createChat());
    late List<MessagePart> parts;
    await tester.runAsync(() async {
      parts = await app.repo.saveAttachments(chat.state.id, [
        testAttachment("shot.png", mimeType: "image/png", bytes: onePixelPng),
        testAttachment("notes.txt"),
      ]);
    });

    await pump(tester, _message(MessageRole.user, parts), chatId: chat.state.id);
    await pumpUntil(tester, find.byType(Image));

    expect(find.byType(Image), findsOneWidget);
    expect(find.text("notes.txt"), findsOneWidget);
  });

  // While the turn is running, the bubble shows the raw text as it streams; a
  // finished message renders markdown. Both so a streaming reply does not
  // re-parse partial markdown on every delta, and so the finished one is read
  // the way it was meant.
  testWidgets("a finished message renders markdown, not the raw syntax", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [const TextPart(text: "here is **bold** code")]),
    );

    expect(find.byType(MarkdownBody), findsOneWidget);
    // The asterisks are consumed by the markdown renderer, so the raw syntax
    // is gone while the word inside it remains.
    expect(find.text("here is **bold** code"), findsNothing);
    expect(find.textContaining("bold"), findsOneWidget);
  });

  testWidgets("a streaming message shows raw text, not a markdown widget", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [const TextPart(text: "here is **bold** code")]),
      isWaiting: true,
    );

    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.text("here is **bold** code"), findsOneWidget);
  });

  testWidgets("tapping a rendered link fires onTapLink with the href", (tester) async {
    String? tapped;
    await pump(
      tester,
      _message(MessageRole.assistant, [const TextPart(text: "see [Flutter](https://flutter.dev)")]),
      onTapLink: (href) => tapped = href,
    );

    await tester.tap(find.textContaining("Flutter"));
    await tester.pumpAndSettle();

    expect(tapped, "https://flutter.dev");
  });
}
