import "dart:convert";
import "dart:typed_data";

import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
// `RenderParagraph`, which material does not re-export.
import "package:flutter/rendering.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:flutter_markdown_plus/flutter_markdown_plus.dart";

import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/theme_colour.dart";
import "package:agent_chat/ui/theme.dart";
import "package:agent_chat/ui/chat/activity/card.dart" show ActivitySource, LiveMessage;
import "package:agent_chat/ui/chat/activity/label.dart" show ActivityGroup;
import "package:agent_chat/ui/chat/widgets/message_bubble.dart";
import "package:agent_chat/ui/chat/widgets/message_text.dart";

import "../fakes.dart";
import "../harness.dart";

Message _message(MessageRole role, List<MessagePart> parts, {String? author}) =>
    Message(
        id: "m1", role: role, createdAt: DateTime(2026), parts: parts, author: author);

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
    String? waitingStatus,
    String? shellOutput,
    List<String>? threads,
    ValueChanged<int>? onThreadStep,
    VoidCallback? onDelete,
    ValueChanged<String>? onEdit,
    VoidCallback? onRegenerate,
    VoidCallback? onSpeak,
    bool isSpeaking = false,
    ValueChanged<String>? onTapLink,
    Uint8List? avatar,
  }) =>
      app.pump(
        tester,
        Scaffold(
          body: MessageBubble(
            chatId: chatId,
            message: message,
            avatar: avatar,
            isWaiting: isWaiting,
            waitingNotice: waitingNotice,
            waitingStatus: waitingStatus,
            shellOutput: shellOutput,
            threads: threads,
            onThreadStep: onThreadStep,
            onDelete: onDelete,
            onEdit: onEdit,
            onRegenerate: onRegenerate,
            onSpeak: onSpeak,
            isSpeaking: isSpeaking,
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

  Finder findTextStarting(String prefix) => find.textContaining(prefix);

  testWidgets("an error part renders in the theme's error colour", (tester) async {
    await pump(tester, _message(MessageRole.assistant, [const ErrorPart(message: "usage limit reached")]));

    final rendered = tester
        .widgetList<Text>(find.byType(Text))
        .firstWhere((t) => t.data?.contains("usage limit reached") ?? false);
    final context = tester.element(find.byType(MessageBubble));
    expect(rendered.style?.color, Theme.of(context).colorScheme.error);
  });

  // A bold seed's container is the seed itself, which the page's own text
  // colour can be unreadable on; the bubble takes the scheme's paired one.
  testWidgets("a user's words take the colour paired with the bubble's fill",
      (tester) async {
    final seed = ThemeColour.boldBlue.seed;
    final theme = entoliTheme(Brightness.light,
        (primary: seed, secondary: null, radius: 12.0));
    await app.pump(
      tester,
      Theme(
        data: theme,
        child: Scaffold(
          body: MessageBubble(
            chatId: "chat-1",
            message: _message(MessageRole.user, [const TextPart(text: "hello")]),
            isWaiting: false,
          ),
        ),
      ),
    );

    final rich = tester.widget<RichText>(find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText() == "hello"));
    Color? colour;
    rich.text.visitChildren((span) {
      colour ??= span.style?.color;
      return colour == null;
    });
    final scheme = theme.colorScheme;
    expect(colour, scheme.onPrimaryContainer);
    expect(scheme.onPrimaryContainer, isNot(scheme.onSurface));
  });

  // A running turn shows a spinner while nothing is being written and a caret
  // at the end of text that is, never both. `hasText` ignores whitespace, so
  // asking it and the caret separately drew both for a blank first flush.
  // Text with a tool call under it finished arriving before the call started,
  // so a caret there would point at nothing. An error still spins (a retry may
  // follow) but is not text being written, so it gets no caret.
  testWidgets("a turn shows a spinner or a caret, never both", (tester) async {
    const call = ToolCallPart(toolCall: ToolCall(id: "1", name: "bash"));
    for (final (parts, waiting, spinner, caret) in [
      (const <MessagePart>[], true, true, false),
      (const <MessagePart>[call], true, true, false),
      (const <MessagePart>[], false, false, false),
      (const <MessagePart>[TextPart(text: "Hel")], true, false, true),
      (const <MessagePart>[TextPart(text: "done")], false, false, false),
      // The spinner here is the live tool label's own, not the message's.
      (const <MessagePart>[TextPart(text: "running it now"), call], true, true, false),
      (const <MessagePart>[TextPart(text: "  ")], true, false, true),
      (const <MessagePart>[ErrorPart(message: "usage limit")], true, true, false),
    ]) {
      await pump(tester, _message(MessageRole.assistant, parts), isWaiting: waiting);
      final why = "$parts, waiting: $waiting";
      expect(find.byType(CircularProgressIndicator),
          spinner ? findsOneWidget : findsNothing, reason: why);
      expect(find.byType(StreamingCaret), caret ? findsOneWidget : findsNothing,
          reason: why);
    }
    // Not `find.text`: a reply still being written ends in a caret, so it is a
    // span, and the caret's placeholder is part of what that span reads as.
    await pump(tester, _message(MessageRole.assistant, [const TextPart(text: "Hel")]),
        isWaiting: true);
    expect(find.textContaining("Hel", findRichText: true), findsOneWidget);
  });

  testWidgets("an addressed reply is named, with its avatar where there is one",
      (tester) async {
    // The circle wraps what it is given in a ResizeImage (the decode budget);
    // what arrives at an Image is read through it.
    Uint8List? shown() {
      final images = tester.widgetList<Image>(find.byType(Image)).toList();
      if (images.isEmpty) return null;
      return ((images.single.image as ResizeImage).imageProvider as MemoryImage)
          .bytes;
    }

    Message reply({String? author}) => _message(
        MessageRole.assistant, [const TextPart(text: "Found them.")],
        author: author);

    await pump(tester, reply(author: "@researcher"), avatar: onePixelPng);
    expect(find.text("@researcher"), findsOneWidget);
    expect(shown(), onePixelPng);

    // No bytes: the label alone.
    await pump(tester, reply(author: "@researcher"));
    expect(find.text("@researcher"), findsOneWidget);
    expect(find.byType(Image), findsNothing);

    // The reply is the page: no name over it when nobody was addressed.
    await pump(tester, reply());
    expect(find.text("@researcher"), findsNothing);
  });

  group("a running command's output", () {
    testWidgets("sits under the spinner, or the label, of the reply it is for",
        (tester) async {
      await pump(
        tester,
        _message(MessageRole.assistant, const []),
        isWaiting: true,
        shellOutput: "one\ntwo\n",
      );
      // The spinner row is the running indication; the block is only the
      // output under it.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining("one\ntwo", findRichText: true), findsOneWidget);

      await pump(
        tester,
        _message(MessageRole.assistant, [
          const TextPart(text: "Checking that."),
          const MessagePart.toolCall(
              toolCall: ToolCall(id: "c1", name: "bash", argumentsText: "ls")),
        ]),
        isWaiting: true,
        shellOutput: "files here\n",
      );
      expect(find.textContaining("Using tool", findRichText: true), findsOneWidget);
      expect(find.textContaining("files here", findRichText: true), findsOneWidget);

      // A message said after the reply is the last one, and so the waiting
      // one; the reply still running its command keeps the block.
      await pump(tester, _message(MessageRole.assistant, [const TextPart(text: "Run.")]),
          shellOutput: "still going\n");
      expect(find.textContaining("still going", findRichText: true), findsOneWidget);
    });

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

  testWidgets("a reply that ended on an error offers Retry, and no other does",
      (tester) async {
    var fired = 0;
    await pump(
      tester,
      _message(MessageRole.assistant, [const ErrorPart(message: "usage limit reached")]),
      onRegenerate: () => fired++,
    );
    await tester.tap(find.text("Retry"));
    await tester.pumpAndSettle();
    expect(fired, 1);

    // Still running; healthy; and failed then carried on, whose stale error is
    // still in the parts but did not end the turn.
    for (final (parts, waiting) in [
      (const <MessagePart>[ErrorPart(message: "rate limited")], true),
      (const <MessagePart>[TextPart(text: "all good")], false),
      (const <MessagePart>[
        ErrorPart(message: "connection lost"),
        TextPart(text: "carried on and finished"),
      ], false),
    ]) {
      await pump(tester, _message(MessageRole.assistant, parts),
          isWaiting: waiting, onRegenerate: () {});
      expect(find.text("Retry"), findsNothing, reason: "$parts");
    }
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

    // A long think is worded in minutes.
    await pump(
      tester,
      _message(MessageRole.assistant, const [ReasoningPart(text: "...", durationMs: 125000)]),
    );

    expect(find.text("Thought for 2 minutes 5 seconds"), findsOneWidget);

    // Nothing timed it — an older conversation, or a turn that was aborted —
    // and the block is still worth opening.
    await pump(tester, _message(MessageRole.assistant, const [ReasoningPart(text: "hmm")]));

    expect(find.text("View thinking"), findsOneWidget);
  });

  // Long output fills the screen rather than stopping at a fraction of it.
  testWidgets("the label opens the thinking in a drawer as tall as it needs",
      (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [
        ReasoningPart(
            text: ["17*23 = 391", ...List.filled(400, "thinking")].join("\n"),
            durationMs: 12000),
      ]),
    );
    await openThinking(tester);

    expect(find.textContaining("17*23 = 391"), findsOneWidget);
    final screen = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(tester.getSize(find.byType(BottomSheet)).height, screen);
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

  testWidgets("two or more activities collapse behind an Expand activities toggle",
      (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [
        ReasoningPart(text: "hmm", durationMs: 1000),
        ToolCallPart(toolCall: ToolCall(id: "c1", name: "bash", argumentsText: "pwd")),
        ToolResultPart(result: ToolResult(callId: "c1", returnCode: 0, output: "/w")),
        TextPart(text: "done"),
      ]),
    );

    expect(find.text("Expand activities"), findsOneWidget);
    expect(find.text("Thought for 1 second"), findsNothing);
    expect(find.text("Used tool: bash"), findsNothing);

    await tester.tap(find.text("Expand activities"));
    await tester.pumpAndSettle();

    expect(find.text("Collapse activities"), findsOneWidget);
    // In the order they happened, above what was said.
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y("Thought for 1 second"), lessThan(y("Used tool: bash")));
    expect(y("Used tool: bash"), lessThan(y("done")));

    await tester.tap(find.text("Collapse activities"));
    await tester.pumpAndSettle();

    expect(find.text("Expand activities"), findsOneWidget);
    expect(find.text("Thought for 1 second"), findsNothing);
    expect(find.text("Used tool: bash"), findsNothing);
  });

  testWidgets("a single activity label renders no toggle", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [
        ToolCallPart(toolCall: ToolCall(id: "c1", name: "bash", argumentsText: "pwd")),
        ToolResultPart(result: ToolResult(callId: "c1", returnCode: 0, output: "/w")),
        TextPart(text: "done"),
      ]),
    );

    expect(find.text("Expand activities"), findsNothing);
    expect(find.text("Used tool: bash"), findsOneWidget);
  });

  testWidgets("an artifact between two runs keeps each run collapsed on its own",
      (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [
        ReasoningPart(text: "hmm", durationMs: 1000),
        ToolCallPart(toolCall: ToolCall(id: "c1", name: "bash", argumentsText: "pwd")),
        ToolResultPart(result: ToolResult(callId: "c1", returnCode: 0, output: "/w")),
        MessagePart.artifact(artifactId: "a1", entryFile: "index.html", title: "Demo"),
        ReasoningPart(text: "more", durationMs: 1000),
        ToolCallPart(toolCall: ToolCall(id: "c2", name: "bash", argumentsText: "ls")),
        ToolResultPart(result: ToolResult(callId: "c2", returnCode: 0, output: "x")),
        TextPart(text: "done"),
      ]),
    );

    expect(find.text("Expand activities"), findsNWidgets(2));
    expect(find.text("Demo"), findsOneWidget);
  });

  testWidgets("a failed tool run inside a sequence stays visible and breaks the run",
      (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [
        ReasoningPart(text: "hmm", durationMs: 1000),
        ToolCallPart(toolCall: ToolCall(id: "c1", name: "bash", argumentsText: "nope")),
        ToolResultPart(result: ToolResult(callId: "c1", returnCode: 1, output: "", exceptionInfo: "boom")),
        ReasoningPart(text: "more", durationMs: 1000),
        ToolCallPart(toolCall: ToolCall(id: "c2", name: "bash", argumentsText: "ls")),
        ToolResultPart(result: ToolResult(callId: "c2", returnCode: 0, output: "x")),
        TextPart(text: "done"),
      ]),
    );

    // The failed call is out in the open; the thinking before it is a lone
    // label (no toggle); the two after it collapse.
    expect(find.text("Used tool: bash"), findsOneWidget);
    expect(find.text("Expand activities"), findsOneWidget);
    expect(find.text("Thought for 1 second"), findsOneWidget);
  });

  group("instructions label", () {
    testWidgets("one file reads by its name, several by a count", (tester) async {
      await pump(
        tester,
        _message(MessageRole.assistant, const [
          MessagePart.instructions(files: [
            InstructionRef(
                path: "/data/AGENTS.md", kind: InstructionKind.global),
          ]),
          MessagePart.instructions(files: [
            InstructionRef(
                path: "/data/AGENTS.md", kind: InstructionKind.global),
            InstructionRef(
                path: "/ws/AGENTS.md", kind: InstructionKind.project),
            InstructionRef(path: "/ws/notes.md", kind: InstructionKind.imported),
          ]),
        ]),
      );

      expect(find.text("Read AGENTS.md"), findsOneWidget);
      expect(find.text("Read 3 instruction files"), findsOneWidget);

      // The drawer says where each file was reached from, never what it said.
      await tester.tap(find.text("Read 3 instruction files"));
      await tester.pumpAndSettle();
      expect(find.text("Instructions"), findsOneWidget);
      expect(find.text("the user's global instructions, for every project"),
          findsOneWidget);
      expect(find.text("project workspace instructions"), findsOneWidget);
      expect(find.text("/ws/AGENTS.md"), findsOneWidget);
    });

    testWidgets("an instructions read breaks the run it sits in", (tester) async {
      await pump(
        tester,
        _message(MessageRole.assistant, const [
          ReasoningPart(text: "before", durationMs: 1000),
          MessagePart.instructions(files: [
            InstructionRef(
                path: "/ws/AGENTS.md", kind: InstructionKind.project),
          ]),
          ReasoningPart(text: "after", durationMs: 1000),
          TextPart(text: "done"),
        ]),
      );

      // The two thinking blocks alone would collapse behind a toggle; on
      // either side of the read they are runs of one, so no toggle at all and
      // the read out in the open.
      expect(find.text("Read AGENTS.md"), findsOneWidget);
      expect(find.text("Expand activities"), findsNothing);
      expect(find.text("Thought for 1 second"), findsNWidgets(2));
    });

    testWidgets("a read tool's drawer cuts the rendered block from its output",
        (tester) async {
      await pump(
        tester,
        _message(MessageRole.assistant, const [
          ToolCallPart(
            toolCall: ToolCall(id: "c1", name: "read", argumentsText: "notes.txt"),
          ),
          ToolResultPart(
            result: ToolResult(
              callId: "c1",
              returnCode: 0,
              output: "1: the contents\n\n"
                  "Workspace instructions are shown below. Be sure to adhere "
                  "to these instructions. IMPORTANT: These instructions "
                  "OVERRIDE any default behavior and you MUST follow them "
                  "exactly as written.\n\n"
                  "Contents of /ws/sub/AGENTS.md (instructions for this "
                  "directory):\n\nsub rules",
            ),
          ),
        ]),
      );

      await tester.tap(find.text("Used tool: read"));
      await tester.pumpAndSettle();

      // The file's own content is there...
      expect(find.textContaining("the contents"), findsOneWidget);
      // ...and the rendered instructions block is not.
      expect(find.textContaining("OVERRIDE any default behavior"),
          findsNothing);
      expect(find.textContaining("sub rules"), findsNothing);
    });
  });

  group("file-tool diffs", () {
    testWidgets("an edit shows red and green lines", (tester) async {
      await pump(
        tester,
        _message(MessageRole.assistant, [
          ToolCallPart(
            toolCall: ToolCall(
              id: "c1",
              name: "edit",
              argumentsJson: jsonEncode({
                "path": "notes.txt",
                "old_string": "old line",
                "new_string": "new line",
              }),
              argumentsText: "notes.txt",
            ),
          ),
          ToolResultPart(result: ToolResult(callId: "c1", returnCode: 0, output: "Edited notes.txt: replaced 1 occurrence(s).")),
        ]),
      );

      expect(find.text("Edited notes.txt"), findsOneWidget);
      expect(find.text("- old line"), findsOneWidget);
      expect(find.text("+ new line"), findsOneWidget);
      expect(find.text("Used tool: edit"), findsNothing);
    });

    testWidgets("a write shows its content as additions", (tester) async {
      await pump(
        tester,
        _message(MessageRole.assistant, [
          ToolCallPart(
            toolCall: ToolCall(
              id: "c1",
              name: "write",
              argumentsJson: jsonEncode({"path": "new.txt", "content": "first\nsecond"}),
              argumentsText: "new.txt",
            ),
          ),
          ToolResultPart(result: ToolResult(callId: "c1", returnCode: 0, output: "Wrote 12 bytes to new.txt")),
        ]),
      );

      expect(find.text("Wrote new.txt"), findsOneWidget);
      expect(find.text("+ first"), findsOneWidget);
      expect(find.text("+ second"), findsOneWidget);
      expect(findTextStarting("- "), findsNothing);
    });

    testWidgets("a change past the budget, or a failed edit, keeps the label",
        (tester) async {
      Message edit(String old, ToolResult result) =>
          _message(MessageRole.assistant, [
            ToolCallPart(
              toolCall: ToolCall(
                id: "c1",
                name: "edit",
                argumentsJson: jsonEncode(
                    {"path": "notes.txt", "old_string": old, "new_string": "here"}),
                argumentsText: "notes.txt",
              ),
            ),
            ToolResultPart(result: result),
          ]);
      for (final message in [
        edit([for (var i = 0; i < 21; i++) "gone $i"].join("\n"),
            const ToolResult(callId: "c1", returnCode: 0, output: "Edited")),
        edit("old line",
            const ToolResult(callId: "c1", returnCode: 1, output: "", exceptionInfo: "not found")),
      ]) {
        await pump(tester, message);
        expect(find.text("Used tool: edit"), findsOneWidget);
        expect(findTextStarting("- "), findsNothing);
      }
    });

  });

  testWidgets("an ask_user question inside a sequence stays visible", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [
        const ReasoningPart(text: "hmm", durationMs: 1000),
        ToolCallPart(
          toolCall: ToolCall(
            id: "a1",
            name: askToolName,
            argumentsJson: jsonEncode({
              "questions": [
                {"question": "Which?", "options": [{"label": "A"}, {"label": "B"}]},
              ],
            }),
          ),
        ),
        ToolResultPart(
          result: ToolResult(callId: "a1", returnCode: 0, output: askAnswers(const [AskQuestion(question: "Which?", options: [AskOption(label: "A")])], ["A"])),
        ),
        const ReasoningPart(text: "ok", durationMs: 1000),
        const ToolCallPart(toolCall: ToolCall(id: "c2", name: "bash", argumentsText: "ls")),
        const ToolResultPart(result: ToolResult(callId: "c2", returnCode: 0, output: "x")),
        const TextPart(text: "done"),
      ]),
    );

    expect(find.text("Which?"), findsOneWidget);
    // The thinking before the question is a lone label; the two after collapse.
    expect(find.text("Expand activities"), findsOneWidget);
  });

  testWidgets("a live block is not collapsed", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [
        ReasoningPart(text: "earlier", durationMs: 1000),
        ReasoningPart(text: "now"),
      ]),
      isWaiting: true,
    );

    expect(find.text("Thinking…"), findsOneWidget);
    expect(find.text("Thought for 1 second"), findsOneWidget);
    expect(find.text("Expand activities"), findsNothing);

    await pump(
      tester,
      _message(MessageRole.assistant, const [
        ReasoningPart(text: "earlier", durationMs: 1000),
        ToolCallPart(toolCall: ToolCall(id: "c1", name: "bash", argumentsText: "sleep 60")),
      ]),
      isWaiting: true,
    );

    expect(find.text("Using tool: bash"), findsOneWidget);
    expect(find.text("Expand activities"), findsNothing);
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

  testWidgets("the actions row offers what it was given", (tester) async {
    // A user message can be edited and regenerated.
    var regenerated = 0;
    await pump(
      tester,
      _message(MessageRole.user, [const TextPart(text: "hello")]),
      onEdit: (_) {},
      onRegenerate: () => regenerated++,
    );

    await reveal(tester, find.text("hello"));

    expect(find.byTooltip("Edit"), findsOneWidget);
    await tester.tap(find.byTooltip("Regenerate"));
    await tester.pumpAndSettle();
    expect(regenerated, 1);

    // An assistant reply can only be regenerated.
    await pump(
      tester,
      _message(MessageRole.assistant, [const TextPart(text: "hi there")]),
      onRegenerate: () {},
    );

    await reveal(tester, find.text("hi there"));

    expect(find.byTooltip("Edit"), findsNothing);
    expect(find.byTooltip("Regenerate"), findsOneWidget);

    // Neither offered: neither is drawn.
    await pump(tester, _message(MessageRole.user, [const TextPart(text: "hello")]));

    await reveal(tester, find.text("hello"));

    expect(find.byTooltip("Regenerate"), findsNothing);
    expect(find.byTooltip("Edit"), findsNothing);
  });

  // The row keeps its height whatever is in it, so a message does not shift
  // under the pointer the moment the icons appear.
  testWidgets("the actions are covered until the message is touched, and again covers them back", (tester) async {
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

    // And touching it again covers them back up.
    await reveal(tester, find.text("hello"));

    expect(actionsOpacity(tester), 0);
  });

  testWidgets("the edit dialog returns what was typed, or nothing on Cancel", (tester) async {
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
    await tester.tap(find.text("Cancel"));
    await tester.pumpAndSettle();

    // Cancelled: the dialog is all it is, nothing sent.
    expect(edited, isNull);

    // And what was typed on it comes back through the callback.
    await tester.tap(find.byTooltip("Edit"));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), "hello");
    await tester.tap(find.text("Send"));
    await tester.pumpAndSettle();

    expect(edited, "hello");
  });

  group("threads", () {
    /// This message as one of [count] threads, at [index]. [stepping] false is
    /// a turn running, where the row is still uncovered but moving is refused.
    Future<void> pumpThread(
      WidgetTester tester, {
      required int index,
      required int count,
      bool stepping = true,
      ValueChanged<int>? onThreadStep,
      VoidCallback? onDelete,
    }) async {
      await pump(
        tester,
        _message(MessageRole.assistant, [const TextPart(text: "an answer")]),
        threads: count == 1
            ? null
            : [for (var i = 0; i < count; i++) i == index ? "m1" : "other$i"],
        onThreadStep: stepping ? (onThreadStep ?? (_) {}) : null,
        onDelete: onDelete,
      );
      await reveal(tester, find.text("an answer"));
    }

    testWidgets("a message nothing was branched at has no counter", (tester) async {
      await pumpThread(tester, index: 0, count: 1);

      expect(find.text("1/1"), findsNothing);
      expect(find.byTooltip("Previous thread"), findsNothing);
      expect(find.byTooltip("Next thread"), findsNothing);
    });

    testWidgets("several threads are counted, with a way between them", (tester) async {
      await pumpThread(tester, index: 1, count: 3);

      expect(find.text("2/3"), findsOneWidget);
      expect(enabled(tester, buttonTipped("Previous thread")), isTrue);
      expect(enabled(tester, buttonTipped("Next thread")), isTrue);
      // Nothing to delete with when no callback is given.
      expect(find.byTooltip("Delete thread"), findsNothing);
    });

    // The arrows do not wrap, so each end is a dead one rather than a way back
    // round to where the reader started.
    testWidgets("the arrows do not wrap", (tester) async {
      await pumpThread(tester, index: 0, count: 2);

      expect(find.text("1/2"), findsOneWidget);
      expect(enabled(tester, buttonTipped("Previous thread")), isFalse);
      expect(enabled(tester, buttonTipped("Next thread")), isTrue);

      await pumpThread(tester, index: 1, count: 2);

      expect(enabled(tester, buttonTipped("Previous thread")), isTrue);
      expect(enabled(tester, buttonTipped("Next thread")), isFalse);
    });

    testWidgets("an arrow says which way it went", (tester) async {
      final steps = <int>[];
      await pumpThread(tester, index: 1, count: 3, onThreadStep: steps.add);

      await tester.tap(find.byTooltip("Previous thread"));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip("Next thread"));
      await tester.pumpAndSettle();

      expect(steps, [-1, 1]);
    });

    testWidgets("deleting asks first, and says what else is there", (tester) async {
      var deleted = 0;
      await pumpThread(tester, index: 1, count: 3, onDelete: () => deleted++);

      await tester.tap(find.byTooltip("Delete thread"));
      await tester.pumpAndSettle();

      expect(find.text("Delete thread"), findsWidgets);
      expect(find.textContaining("The other 2 stay"), findsOneWidget);
      expect(deleted, 0);

      await tester.tap(find.widgetWithText(TextButton, "Delete"));
      await tester.pumpAndSettle();

      expect(deleted, 1);
    });

    testWidgets("a cancelled confirmation deletes nothing", (tester) async {
      var deleted = 0;
      await pumpThread(tester, index: 0, count: 1, onDelete: () => deleted++);

      await tester.tap(find.byTooltip("Delete thread"));
      await tester.pumpAndSettle();
      // The last thread at a branch takes the rest of the conversation with it,
      // which the wording has to say rather than counting what stays.
      expect(find.textContaining("everything below it"), findsOneWidget);
      expect(find.textContaining("stay"), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, "Cancel"));
      await tester.pumpAndSettle();

      expect(deleted, 0);
    });

    // The row is uncovered while a turn runs, and delete disappears there. The
    // arrows have to say the same thing rather than looking live and doing
    // nothing when tapped.
    testWidgets("the arrows are dead while a turn is running", (tester) async {
      await pumpThread(tester, index: 1, count: 3, stepping: false);

      expect(find.text("2/3"), findsOneWidget);
      expect(enabled(tester, buttonTipped("Previous thread")), isFalse);
      expect(enabled(tester, buttonTipped("Next thread")), isFalse);
    });
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

    await pump(
      tester,
      _message(MessageRole.assistant, [const TextPart(text: "here is **bold** code")]),
      isWaiting: true,
    );
    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.textContaining("here is **bold** code", findRichText: true),
        findsOneWidget);
  });

  group("the message as text", () {
    testWidgets("the copy buttons take it as it reads, and as it is kept",
        (tester) async {
      final copied = clipboard(tester);
      await pump(
        tester,
        _message(MessageRole.assistant, [
          const ReasoningPart(text: "thinking", durationMs: 12000),
          const TextPart(text: "here is **bold** code"),
        ]),
      );
      await reveal(tester, find.textContaining("bold"));

      // What was said, not what was thought, and as it reads rather than as
      // it is kept.
      await tester.tap(find.byTooltip("Copy message"));
      await tester.pumpAndSettle();
      expect(copied, ["here is bold code"]);

      // The raw button is the kept form.
      await tester.tap(find.byTooltip("Copy raw markdown"));
      await tester.pumpAndSettle();
      expect(copied, ["here is bold code", "here is **bold** code"]);
    });

    testWidgets("formatted copy separates a heading from its paragraph, raw copy does not",
        (tester) async {
      final copied = clipboard(tester);
      await pump(
        tester,
        _message(MessageRole.assistant,
            [const TextPart(text: "# Heading\n\nhere is **bold** code")]),
      );
      await reveal(tester, find.textContaining("bold"));

      await tester.tap(find.byTooltip("Copy message"));
      await tester.pumpAndSettle();
      expect(copied.single, "Heading\nhere is bold code");

      await tester.tap(find.byTooltip("Copy raw markdown"));
      await tester.pumpAndSettle();
      expect(copied.last, "# Heading\n\nhere is **bold** code");
    });

    testWidgets("the read-aloud button offers to stop while it is reading",
        (tester) async {
      var pressed = 0;
      await pump(
        tester,
        _message(MessageRole.assistant, [const TextPart(text: "hello")]),
        onSpeak: () => pressed++,
      );
      await reveal(tester, find.text("hello"));

      await tester.tap(find.byTooltip("Read aloud"));
      await tester.pumpAndSettle();
      expect(pressed, 1);

      await pump(
        tester,
        _message(MessageRole.assistant, [const TextPart(text: "hello")]),
        onSpeak: () {},
        isSpeaking: true,
      );
      // Up without being uncovered: stopping must not mean going looking for
      // the button that started it.
      expect(actionsOpacity(tester), 1);
      expect(find.byTooltip("Stop reading"), findsOneWidget);
    });

    testWidgets("a message with nothing said in it has nothing to copy", (tester) async {
      await pump(
        tester,
        _message(MessageRole.assistant, [
          const ToolCallPart(toolCall: ToolCall(id: "1", name: "bash")),
        ]),
      );
      await reveal(tester, find.byType(MessageBubble));

      expect(find.byTooltip("Copy message"), findsNothing);
    });

    // A selection used to stop at the element it started in, and copied whole
    // parts as markdown rather than what was highlighted.
    testWidgets("selecting a rendered reply copies the words on screen",
        (tester) async {
      final copied = clipboard(tester);
      await pump(
        tester,
        _message(MessageRole.assistant,
            [const TextPart(text: "# Heading\n\nhere is **bold** code")]),
      );

      final rendered = find.byType(MarkdownBody);
      await dragCopy(
        tester,
        tester.getTopLeft(rendered) + const Offset(2, 4),
        to: tester.getBottomRight(rendered) - const Offset(2, 4),
      );

      expect(copied, ["Heading\nhere is bold code"]);
    });

    // The bubble closes at every tool call, so a region per bubble would stop
    // the drag at the first one — which is most of the replies this app makes.
    testWidgets("a drag crosses a tool label without picking it up", (tester) async {
      final copied = clipboard(tester);
      await pump(
        tester,
        _message(MessageRole.assistant, [
          const TextPart(text: "before **the** call"),
          const ToolCallPart(toolCall: ToolCall(id: "1", name: "bash")),
          const TextPart(text: "after *it*"),
        ]),
      );

      final said = find.byType(MarkdownBody);
      await dragCopy(
        tester,
        tester.getTopLeft(said.first) + const Offset(2, 4),
        to: tester.getBottomRight(said.last) - const Offset(2, 4),
      );

      expect(copied.single, contains("before the call"));
      expect(copied.single, contains("after it"));
      expect(copied.single, isNot(contains("bash")));
    });

    // The bullets are chrome like a code block's bar: what a selection reads
    // is what the copy button reads, the list's items and not `•Item`.
    testWidgets("a drag over a list copies its items without the bullets",
        (tester) async {
      final copied = clipboard(tester);
      await pump(
        tester,
        _message(MessageRole.assistant, [const TextPart(text: "- one\n- two")]),
      );

      final rendered = find.byType(MarkdownBody);
      await dragCopy(
        tester,
        tester.getTopLeft(rendered) + const Offset(2, 4),
        to: tester.getBottomRight(rendered) - const Offset(2, 4),
      );

      expect(copied.single, "one\ntwo");
    });

    // Whole-part copy answered a three-word drag with the whole paragraph's
    // markdown; a selection copies the range it covers, and only that.
    testWidgets("selecting part of a paragraph copies only what it covered",
        (tester) async {
      final copied = clipboard(tester);
      await pump(
        tester,
        _message(
            MessageRole.assistant, [const TextPart(text: "the first words")]),
      );

      // The caret position of the range's ends, laid out: 4 is before
      // "first", 10 is before "words", so the drag covers "first" alone.
      // Positions rather than guessed widths.
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(MarkdownBody),
          matching: find.textContaining("the first words", findRichText: true),
        ),
      );
      Offset at(int index) =>
          tester.getTopLeft(find.byType(MarkdownBody)) +
          paragraph.getOffsetForCaret(TextPosition(offset: index), Rect.fromLTWH(0, 0, 400, 14)) +
          const Offset(0, 7);

      await dragCopy(tester, at(4), to: at(10));

      // A trailing space is inside what was dragged: the highlight reaches to
      // the caret before "words", and the space before it is under it.
      expect(copied.single, "first ");
    });

    // A collapsed selection is a tap, not a copy: writing the empty string
    // would report success over nothing.
    testWidgets("a selection collapsed to a point copies nothing", (tester) async {
      final copied = clipboard(tester);
      await pump(
        tester,
        _message(MessageRole.assistant, [const TextPart(text: "hello there")]),
      );

      final rendered = find.byType(MarkdownBody);
      await dragCopy(tester, tester.getTopLeft(rendered) + const Offset(2, 4));

      expect(copied, isEmpty);
    });

    testWidgets("the copy button carries the message as HTML too", (tester) async {
      final html = <String>[];
      clipboard(tester, html: html);
      await pump(
        tester,
        _message(MessageRole.assistant,
            [const TextPart(text: "# Heading\n\nhere is **bold** <code>")]),
      );
      await reveal(tester, find.textContaining("bold"));

      await tester.tap(find.byTooltip("Copy message"));
      await tester.pumpAndSettle();
      expect(html.single, contains("<h1>Heading</h1>"));
      expect(html.single, contains("<strong>bold</strong> &lt;code&gt;"));
    });

    Future<void> dragOver(WidgetTester tester, {bool copy = true}) async {
      final rendered = find.byType(MarkdownBody);
      final from = tester.getTopLeft(rendered.first) + const Offset(2, 4);
      final to = tester.getBottomRight(rendered.last) - const Offset(2, 4);
      if (copy) return dragCopy(tester, from, to: to);
      final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets("Ctrl+C over a selection carries its formatting", (tester) async {
      final html = <String>[];
      clipboard(tester, html: html);
      await pump(
        tester,
        _message(MessageRole.assistant, [
          const TextPart(
              text: "# Heading\n\nhere is **bold**, *it* and `code`, "
                  "[a link](https://example.com)\n\n1. one\n2. two"),
        ]),
      );

      await dragOver(tester);

      final copied = html.single;
      expect(copied, contains("<h1>Heading</h1>"));
      expect(copied, contains("<b>bold</b>"));
      expect(copied, contains("<i>it</i>"));
      expect(copied, matches(RegExp(r"<code[^>]*>code</code>")));
      expect(copied, contains('<a href="https://example.com">a link</a>'));
      expect(copied, contains("<ol><li>one</li><li>two</li></ol>"));
    });

    // The bullet goes with the item's start: a drag from inside "hello" did
    // not pick the item up, only some of its words.
    testWidgets("part of a list item copies as words, the whole item as an item",
        (tester) async {
      final html = <String>[];
      clipboard(tester, html: html);
      await pump(
        tester,
        _message(MessageRole.assistant, [const TextPart(text: "- hello\n- there")]),
      );

      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(MarkdownBody),
          matching: find.text("hello", findRichText: true),
        ),
      );
      Offset at(int index) =>
          paragraph.localToGlobal(paragraph.getOffsetForCaret(
              TextPosition(offset: index), Rect.zero)) +
          const Offset(0, 7);

      await dragCopy(tester, at(1), to: at(5));
      expect(html.single, isNot(contains("<li>")));
      expect(html.single, contains("<p>ello</p>"));

      await dragCopy(tester, at(0), to: at(5));
      expect(html.last, contains("<ul><li>hello</li></ul>"));
    });

    // The paragraph after a table or list used to be written before either
    // was closed, inside its last row or item, where a paste drops it.
    testWidgets("a block after a table or a list is outside it", (tester) async {
      final html = <String>[];
      clipboard(tester, html: html);
      await pump(
        tester,
        _message(MessageRole.assistant, [
          const TextPart(
              text: "before\n\n| a | b |\n|---|---|\n| c | d |\n\nbetween\n\n- one\n\nafter"),
        ]),
      );

      await dragOver(tester);

      expect(html.single, contains("<td style=\"border: 1px solid #d0d7de; padding: 4px 8px\">d</td></tr></table><p>between</p>"));
      expect(html.single, contains("<ul><li>one</li></ul><p>after</p>"));
    });

    testWidgets("a selected code block copies as preformatted text", (tester) async {
      final html = <String>[];
      clipboard(tester, html: html);
      await pump(
        tester,
        _message(MessageRole.assistant,
            [const TextPart(text: "read this:\n\n```\nprint(1)\n```")]),
      );

      await dragOver(tester);

      expect(html.single, contains("<p>read this:</p>"));
      expect(html.single, matches(RegExp(r"<pre[^>]*>print\(1\)\n?</pre>")));
    });

    testWidgets("the selection menu's Copy carries the formatting", (tester) async {
      final html = <String>[];
      clipboard(tester, html: html);
      await pump(
        tester,
        _message(MessageRole.assistant, [const TextPart(text: "here is **bold**")]),
      );

      await dragOver(tester, copy: false);
      await tester.tapAt(
        tester.getCenter(find.byType(MarkdownBody)),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text("Copy"));
      await tester.pumpAndSettle();

      expect(html.single, contains("<p>here is <b>bold</b></p>"));
    });
  });

  // The reply is the page; the prompt is something said to one side of it, so
  // only the prompt is tinted and named.
  testWidgets("only the prompt has a bubble and a name", (tester) async {
    Finder tint() =>
        find.ancestor(of: find.byType(MarkdownBody), matching: find.byType(Container));

    await pump(tester, _message(MessageRole.assistant, [const TextPart(text: "hello")]));
    expect(tint(), findsNothing);
    expect(find.text("Assistant"), findsNothing);

    await pump(tester, _message(MessageRole.user, [const TextPart(text: "hello")]));
    expect(tint(), findsOneWidget);
    expect(find.text("You"), findsOneWidget);
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

  testWidgets("an artifact part shows a label that opens it on tap", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [
        const MessagePart.artifact(artifactId: "art-1", entryFile: "index.html", title: "Demo"),
      ]),
    );

    expect(find.textContaining("Demo"), findsOneWidget);

    await tester.tap(find.textContaining("Demo"));
    await tester.pumpAndSettle();

    expect(app.linkOpener.openedArtifacts, hasLength(1));
    expect(app.linkOpener.openedArtifacts.single.chatId, "chat-1");
    expect(app.linkOpener.openedArtifacts.single.artifactId, "art-1");
    expect(app.linkOpener.openedArtifacts.single.entryFile, "index.html");
    expect(app.linkOpener.openedArtifacts.single.title, "Demo");

    await pump(
      tester,
      _message(MessageRole.assistant, [
        const MessagePart.artifact(artifactId: "art-2", entryFile: "chart.html", title: ""),
      ]),
    );
    expect(find.text("View artifact"), findsOneWidget);
  });

  group("a command the user ran", () {
    testWidgets("shows the command without the bang that sent it", (tester) async {
      await pump(
        tester,
        _message(MessageRole.user, const [MessagePart.text(text: "!echo hello")]),
      );

      expect(find.text("echo hello"), findsOneWidget);
      expect(find.byIcon(Icons.terminal), findsOneWidget);
      expect(find.byType(MarkdownBody), findsNothing);
    });

    testWidgets("what it printed and what it exited with are both shown",
        (tester) async {
      await pump(
        tester,
        _message(MessageRole.assistant, const [
          MessagePart.shellRun(command: "echo hello", returnCode: 0, output: "hello\n"),
        ]),
      );

      expect(find.text("hello"), findsOneWidget);
      expect(find.text("Exit code: 0"), findsOneWidget);

      // Nothing printed: said, so it does not read as cut off.
      await pump(
        tester,
        _message(MessageRole.assistant, const [
          MessagePart.shellRun(command: "true", returnCode: 0, output: ""),
        ]),
      );

      expect(find.text("Exit code: 0"), findsOneWidget);
      expect(find.text("no output"), findsOneWidget);
    });

    testWidgets("one that could not run says why", (tester) async {
      await pump(
        tester,
        _message(MessageRole.assistant, const [
          MessagePart.shellRun(
            command: "ls",
            returnCode: -1,
            output: "",
            exceptionInfo: "There is no shell here to execute commands in.",
          ),
        ]),
      );

      expect(find.text("Exit code: -1"), findsOneWidget);
      expect(find.textContaining("no shell here"), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    // It is a message like any other, and resending re-parses it into the same
    // command.
    testWidgets("can still be edited and regenerated", (tester) async {
      await pump(
        tester,
        _message(MessageRole.user, const [MessagePart.text(text: "!echo hello")]),
        onEdit: (_) {},
        onRegenerate: () {},
      );
      await reveal(tester, find.text("echo hello"));

      expect(enabled(tester, buttonTipped("Edit")), isTrue);
      expect(enabled(tester, buttonTipped("Regenerate")), isTrue);
    });
  });
  group("recorded permissions", () {
    MessagePart part(String answer) => MessagePart.approval(
          approvalId: "a-1",
          toolName: "bash",
          argumentsText: "git status",
          answer: answer,
        );

    testWidgets("the recorded answers read what they granted", (tester) async {
      // Allowed, plainly.
      await pump(tester, _message(MessageRole.assistant, [part("allow")]));

      expect(find.textContaining("Permission: bash — allowed"), findsOneWidget);

      // The scoped answers name what they granted.
      await pump(tester, _message(MessageRole.assistant, [
        part("alwaysAllowChat"),
        MessagePart.approval(
            approvalId: "a-2",
            toolName: "bash",
            answer: "alwaysAllowProject"),
      ]));

      expect(
          find.textContaining("allowed, always in this chat"), findsOneWidget);
      expect(find.textContaining("allowed, always in this project"),
          findsOneWidget);

      // Denied: the wording is the contract; the icon carries the alarm.
      await pump(tester, _message(MessageRole.assistant, [part("deny")]));

      expect(find.textContaining("Permission: bash — denied"), findsOneWidget);
      expect(find.byIcon(Icons.gpp_maybe_outlined), findsOneWidget);

      // A banner the turn left outstanding was never answered.
      await pump(tester, _message(MessageRole.assistant, [part("asked")]));

      expect(find.textContaining("never answered"), findsOneWidget);
    });

    testWidgets("the drawer names the granted dirs", (tester) async {
      await pump(tester, _message(MessageRole.assistant, [
        MessagePart.approval(
            approvalId: "a-3",
            toolName: "bash",
            argumentsText: "writing /home/x",
            deniedDirs: const ["/home/x"],
            answer: "alwaysAllowProject"),
      ]));

      await tester.tap(find.textContaining("Permission: bash"));
      await tester.pumpAndSettle();

      expect(find.text("Sandbox dirs granted"), findsOneWidget);
      expect(find.text("/home/x"), findsOneWidget);
      expect(find.text("Answer"), findsOneWidget);
    });

    testWidgets("a recorded permission breaks an activity run", (tester) async {
      await pump(tester, _message(MessageRole.assistant, [
        const TextPart(text: "checking"),
        part("allow"),
        part("allow"),
      ]));

      // A recorded permission is the user's own decision: it breaks the run
      // of labels rather than collapsing behind a toggle.
      expect(find.byType(ActivityGroup), findsNothing);
      expect(find.textContaining("Permission: bash"), findsNWidgets(2));
    });

    testWidgets("the outcome on the label reads its source and tier", (tester) async {
      // A rule in this chat's tier said so.
      await pump(tester, _message(MessageRole.assistant, [
        MessagePart.toolCall(
            toolCall: const ToolCall(
                id: "call-1", name: "bash", argumentsText: "git status")),
        MessagePart.toolResult(result: const ToolResult(
            callId: "call-1",
            returnCode: 0,
            output: "",
            decidedBy: PermissionSource.rule,
            decidedTier: [PermissionTier.chat],
            decided: PermissionDecision.allow)),
        part("allow"),
      ]));

      expect(find.textContaining("allowed by this chat's rules"),
          findsOneWidget);

      // "allowed, always in this chat" already says the scope; the outcome
      // would say it a second time, so the human+once grant repeats nothing.
      await pump(tester, _message(MessageRole.assistant, [
        MessagePart.toolCall(
            toolCall: const ToolCall(
                id: "call-1", name: "bash", argumentsText: "git status")),
        MessagePart.toolResult(result: const ToolResult(
            callId: "call-1",
            returnCode: 0,
            output: "",
            decidedBy: PermissionSource.human,
            decidedTier: [PermissionTier.once],
            decided: PermissionDecision.allow)),
        part("alwaysAllowChat"),
      ]));

      expect(find.textContaining("Permission: bash — allowed, always in this chat"),
          findsOneWidget);
      expect(find.textContaining("by the rules of"), findsNothing);

      // A rule refusal reads what refused it.
      await pump(tester, _message(MessageRole.assistant, [
        MessagePart.toolCall(
            toolCall: const ToolCall(
                id: "call-1", name: "bash", argumentsText: "rm -rf build")),
        MessagePart.toolResult(result: const ToolResult(
            callId: "call-1",
            returnCode: -1,
            output: "",
            exceptionInfo: "Denied by a permission rule you set.",
            decidedBy: PermissionSource.rule,
            decidedTier: [PermissionTier.project],
            decided: PermissionDecision.deny)),
      ]));

      expect(find.textContaining("denied by the project's rules"),
          findsOneWidget);
    });

    testWidgets("the drawer carries the Outcome section", (tester) async {
      await pump(tester, _message(MessageRole.assistant, [
        MessagePart.toolCall(
            toolCall: const ToolCall(
                id: "call-1", name: "bash", argumentsText: "git status")),
        MessagePart.toolResult(result: const ToolResult(
            callId: "call-1",
            returnCode: 0,
            output: "clean",
            decidedBy: PermissionSource.classifier,
            decidedTier: [],
            decided: PermissionDecision.allow)),
      ]));

      await tester.tap(find.textContaining("Used tool: bash"));
      await tester.pumpAndSettle();

      expect(find.text("Outcome"), findsOneWidget);
      expect(find.text("allowed by the classifier"), findsOneWidget);
    });

    testWidgets("a result with no decision on it says nothing", (tester) async {
      // A result recorded before the field existed.
      await pump(tester, _message(MessageRole.assistant, [
        MessagePart.toolCall(
            toolCall: const ToolCall(
                id: "call-1", name: "bash", argumentsText: "git status")),
        MessagePart.toolResult(result: const ToolResult(
            callId: "call-1", returnCode: 0, output: "old log")),
      ]));

      expect(find.textContaining("Used tool: bash — "), findsNothing);
      expect(find.text("Outcome"), findsNothing);

      // A read inside the workspace ran with nothing standing in front of it:
      // the mode's default posture is not a decision to record.
      await pump(tester, _message(MessageRole.assistant, [
        MessagePart.toolCall(
            toolCall: const ToolCall(
                id: "call-1", name: "read", argumentsText: "notes.txt")),
        MessagePart.toolResult(result: const ToolResult(
            callId: "call-1", returnCode: 0, output: "hi")),
      ]));

      expect(find.textContaining("Used tool: read"), findsOneWidget);
      expect(find.text("Outcome"), findsNothing);
    });
  });

  group("sandbox violations on a tool label", () {
    testWidgets("a clean return with violations reads failed in the error colour",
        (tester) async {
      await pump(tester, _message(MessageRole.assistant, [
        MessagePart.toolCall(
            toolCall: const ToolCall(
                id: "c-1", name: "bash", argumentsText: "python3 build.py")),
        MessagePart.toolResult(result: const ToolResult(
            callId: "c-1",
            returnCode: 0,
            output: "mkdir: cannot create directory '/etc/x': Permission denied",
            violations: ["writing /etc/x"])),
      ]));

      // The wording is the contract; the icon carries the alarm visually.
      expect(find.textContaining("Used tool: bash"), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);

      await tester.tap(find.textContaining("Used tool: bash"));
      await tester.pumpAndSettle();
      expect(find.text("Sandbox"), findsOneWidget);
      expect(find.text("writing /etc/x"), findsOneWidget);
    });

  });

  testWidgets("a thought being written streams under its label", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const [ReasoningPart(text: "weighing the options")]),
      isWaiting: true,
    );

    expect(find.text("Thinking…"), findsOneWidget);
    expect(find.text("weighing the options"), findsOneWidget);

    // Closed, it is a label again and the thought is behind it.
    await pump(
      tester,
      _message(MessageRole.assistant, const [
        ReasoningPart(text: "weighing the options", durationMs: 12000),
        TextPart(text: "done"),
      ]),
    );

    expect(find.text("weighing the options"), findsNothing);
  });

  testWidgets("a drawer with little in it still opens at most of the screen",
      (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant,
          const [ReasoningPart(text: "short", durationMs: 12000)]),
    );
    await openThinking(tester);

    final screen = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(tester.getSize(find.byType(BottomSheet)).height, greaterThan(screen * 0.5));
  });

  testWidgets("an open drawer streams what its message goes on to say",
      (tester) async {
    Message thought(String text, {int? durationMs}) => _message(
        MessageRole.assistant, [ReasoningPart(text: text, durationMs: durationMs)]);
    final live = NotifierProvider<_Live, LiveMessage>(
        () => _Live((message: thought("first"), shellOutput: null, running: true)));
    await app.pump(
      tester,
      Scaffold(
        body: Consumer(
          builder: (context, ref, _) => ActivitySource(
            live: live,
            child: MessageBubble(
              chatId: "chat-1",
              message: ref.watch(live).message!,
              isWaiting: true,
            ),
          ),
        ),
      ),
      settle: false,
    );
    await tester.tap(find.text("Thinking…"));
    await tester.pump(const Duration(milliseconds: 500));

    final sheet = find.byType(BottomSheet);
    expect(find.descendant(of: sheet, matching: find.textContaining("first")), findsOneWidget);

    app.container.read(live.notifier).state =
        (message: thought("first then more"), shellOutput: null, running: true);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.descendant(of: sheet, matching: find.textContaining("first then more")),
        findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.byType(CircularProgressIndicator)),
        findsOneWidget);

    // The block closing ends the stream, with the drawer still up.
    app.container.read(live.notifier).state = (
      message: thought("first then more", durationMs: 3000),
      shellOutput: null,
      running: false,
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.descendant(of: sheet, matching: find.byType(CircularProgressIndicator)),
        findsNothing);
  });

  testWidgets("a sub-agent's drawer draws its transcript as it is written",
      (tester) async {
    const task = ToolCall(
      id: "call-1",
      name: "task",
      argumentsJson: '{"agent":"general","prompt":"look it up"}',
    );
    final parent = _message(MessageRole.assistant, const [ToolCallPart(toolCall: task)]);
    final live = NotifierProvider<_Live, LiveMessage>(
        () => _Live((message: parent, shellOutput: null, running: true)));
    final feed = app.backend.subAgents
      ..open("chat-1", "call-1", const [])
      ..add("chat-1", "call-1", [
        ChatRecord.message(
            id: "call-1", role: MessageRole.assistant, createdAt: DateTime(2026)),
        const ChatRecord.part(
            messageId: "call-1", index: 0, part: TextPart(text: "Searching first.")),
      ]);
    await app.pump(
      tester,
      Scaffold(
        body: ActivitySource(
          live: live,
          child: MessageBubble(chatId: "chat-1", message: parent, isWaiting: true),
        ),
      ),
      settle: false,
    );

    await tester.tap(find.text("Running sub-agent @general"));
    await tester.pump(const Duration(milliseconds: 500));
    // The transcript is read as the drawer first builds, and lands a frame on.
    await tester.pump(const Duration(milliseconds: 100));
    final sheet = find.byType(BottomSheet);
    expect(
        find.descendant(
            of: sheet,
            matching: find.textContaining("Searching first.", findRichText: true)),
        findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text("Output")), findsNothing);

    feed.add("chat-1", "call-1", const [
      ChatRecord.part(
          messageId: "call-1",
          index: 1,
          part: ToolCallPart(
              toolCall: ToolCall(
                  id: "s1", name: "websearch", argumentsJson: '{"query":"cyprus"}'))),
    ]);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.descendant(of: sheet, matching: find.textContaining("cyprus")),
        findsOneWidget);
  });
}

class _Live extends Notifier<LiveMessage> {
  _Live(this.initial);

  final LiveMessage initial;

  @override
  LiveMessage build() => initial;
}
