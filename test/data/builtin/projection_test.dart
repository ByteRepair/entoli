import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/projection.dart";
import "package:agent_chat/data/builtin/templates.dart";
import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/domain/end_turn.dart";
import "package:agent_chat/domain/models.dart";

void main() {
  final at = DateTime.utc(2026, 1, 1);
  var next = 0;

  Message said(MessageRole role, List<MessagePart> parts) =>
      Message(id: "m${next++}", role: role, createdAt: at, parts: parts);

  Message asked(String text) => said(MessageRole.user, [MessagePart.text(text: text)]);

  MessagePart call(String id, String name, String arguments, {String? response}) =>
      MessagePart.toolCall(
        toolCall: ToolCall(id: id, name: name, argumentsJson: arguments),
        responseId: response,
      );

  MessagePart ran(String id, String output, {int returnCode = 0}) => MessagePart.toolResult(
      result: ToolResult(callId: id, returnCode: returnCode, output: output));

  /// Nothing in this file is about attachment bytes except the two tests that
  /// pass a loader of their own.
  Future<List<LlmMessage>> project(List<Message> messages,
          {bool first = true,
          String? viewer,
          List<ConversationCompaction> compactions = const []}) =>
      projectionOf(messages,
          first: first,
          load: noResources,
          viewer: viewer,
          compactions: compactions);

  setUp(() => next = 0);

  test("a plain exchange goes back as one message each way", () async {
    final projected = await project([
      asked("what is 2+2?"),
      said(MessageRole.assistant, const [MessagePart.text(text: "four")]),
    ]);

    // The user's turn is worded by [userTurnText] rather than handed back raw:
    // it is what the live turn sent, so it is what a rebuilt session has to
    // send too — the date off the message, and the task framing on the one that
    // opened the chat.
    expect(projected.map((m) => (m.role, m.text)), [
      (LlmRole.user, userTurnText("what is 2+2?", at: at, first: true)),
      (LlmRole.assistant, "four"),
    ]);
  });

  test("only the message that opens the conversation is dressed as a task", () async {
    final projected = await project([
      asked("first"),
      said(MessageRole.assistant, const [MessagePart.text(text: "ok")]),
      asked("second"),
    ]);

    expect(projected.first.text, userTurnText("first", at: at, first: true));
    expect(projected.last.text, userTurnText("second", at: at, first: false));
    expect(projected.last.text, isNot(contains("The user asks")));
  });

  test("a fragment appended to a session already holding the rest opens nothing",
      () async {
    // What `_runBypass` projects: the two messages its turn is writing, onto a
    // session that already has the conversation.
    final projected = await project([asked("later")], first: false);

    expect(projected.single.text, userTurnText("later", at: at, first: false));
  });

  test("thinking travels with the response it belongs to, signature and all", () async {
    final projected = await project([
      asked("go on"),
      said(MessageRole.assistant, const [
        MessagePart.reasoning(text: "weighing it up", durationMs: 20, signature: "sig-1", responseId: "r1"),
        MessagePart.text(text: "here goes", responseId: "r1"),
      ]),
    ]);

    final reply = projected.last;
    expect(reply.reasoning, "weighing it up");
    expect(reply.reasoningSignature, "sig-1");
    expect(reply.text, "here goes");
  });

  test("a turn of several responses goes back as one message each", () async {
    final projected = await project([
      asked("list the files"),
      said(MessageRole.assistant, [
        const MessagePart.reasoning(text: "have a look", responseId: "r1"),
        call("c1", "bash", '{"command":"ls"}', response: "r1"),
        ran("c1", "notes.txt"),
        const MessagePart.text(text: "one file: notes.txt", responseId: "r2"),
      ]),
    ]);

    expect(projected.map((m) => m.role), [
      LlmRole.user,
      LlmRole.assistant,
      LlmRole.tool,
      LlmRole.assistant,
    ]);
    expect(projected[1].reasoning, "have a look");
    expect(projected[1].toolCalls.single.id, "c1");
    expect(projected[2].toolCallId, "c1");
    expect(projected[2].text, contains("notes.txt"));
    // The second response's text is its own message, not folded into the first
    // — the tool result has to sit between them.
    expect(projected[3].text, "one file: notes.txt");
    expect(projected[3].toolCalls, isEmpty);
  });

  test("a result is worded the way the agent worded it when it ran", () async {
    final projected = await project([
      said(MessageRole.assistant, [
        call("c1", "bash", '{"command":"false"}', response: "r1"),
        ran("c1", "nope", returnCode: 1),
      ]),
    ]);

    expect(projected.last.text, observation(returnCode: 1, output: "nope"));
  });

  MessagePart moved(String id, String cwd, {String output = ""}) =>
      MessagePart.toolResult(
        result: ToolResult(
            callId: id, returnCode: 0, output: output, cwd: cwd),
      );

  // The note is derived at wording time from the directory the result carries,
  // so the parts worded live and the same parts worded on a reload say the
  // same thing.
  group("the directory a command leaves the shell in", () {
    test("the turn's opening move is not noted: the model ran the cd itself",
        () async {
      final projected = await project([
        said(MessageRole.assistant, [
          call("c1", "bash", '{"command":"cd elsewhere"}', response: "r1"),
          moved("c1", "/elsewhere"),
        ]),
      ]);

      expect(projected.last.text, observation(returnCode: 0, output: ""));
    });

    test("a later move in the same turn is noted, after the observation",
        () async {
      final projected = await project([
        said(MessageRole.assistant, [
          call("c1", "bash", '{"command":"cd one"}', response: "r1"),
          moved("c1", "/one"),
          call("c2", "bash", '{"command":"cd two"}', response: "r1"),
          moved("c2", "/two"),
        ]),
      ]);

      final tools = projected.where((m) => m.role == LlmRole.tool).toList();
      expect(tools[0].text, observation(returnCode: 0, output: ""));
      expect(tools[1].text,
          "${observation(returnCode: 0, output: "")}\n\n"
          "Note: your current working directory is now /two.");
    });

    test("a command that stays where it is says nothing new", () async {
      final projected = await project([
        said(MessageRole.assistant, [
          call("c1", "bash", '{"command":"cd one"}', response: "r1"),
          moved("c1", "/one"),
          call("c2", "bash", '{"command":"ls"}', response: "r1"),
          moved("c2", "/one", output: "here"),
        ]),
      ]);

      final tools = projected.where((m) => m.role == LlmRole.tool).toList();
      expect(tools[1].text, observation(returnCode: 0, output: "here"));
    });

    test("and the tracking resets at each turn", () async {
      final projected = await project([
        asked("move"),
        said(MessageRole.assistant, [
          call("c1", "bash", '{"command":"cd one"}', response: "r1"),
          moved("c1", "/one"),
        ]),
        asked("move again"),
        said(MessageRole.assistant, [
          call("c2", "bash", '{"command":"cd two"}', response: "r1"),
          moved("c2", "/two"),
        ]),
      ]);

      final tools = projected.where((m) => m.role == LlmRole.tool).toList();
      // Each turn's opening move is un-noted, the model having run the `cd`
      // itself, whatever the previous turn left the shell in.
      expect(tools[0].text, observation(returnCode: 0, output: ""));
      expect(tools[1].text, observation(returnCode: 0, output: ""));
    });
  });

  // The answers are the answer; wrapping them as a command's outcome would put
  // the user's own words behind a return code.
  test("an ask_user result goes back as the answers themselves", () async {
    final projected = await project([
      said(MessageRole.assistant, [
        call("a1", askToolName, '{"questions":[]}', response: "r1"),
        ran("a1", "Which one? Rust"),
      ]),
    ]);

    expect(projected.last.text, "Which one? Rust");
  });

  // A command's effects outlive the process that ran it, so "not executed"
  // would be a guess — and the wrong one half the time.
  test("a call whose result never landed is answered anyway", () async {
    final projected = await project([
      said(MessageRole.assistant, [
        call("c1", "bash", '{"command":"make install"}', response: "r1"),
      ]),
    ]);

    expect(projected.last.role, LlmRole.tool);
    expect(projected.last.toolCallId, "c1");
    expect(projected.last.text, contains("interrupted"));
    expect(projected.last.text, contains("may or may not have run"));
    expect(projected.last.text, isNot(contains("not executed")));
  });

  // The answered form is the answers themselves, so the unanswered one is
  // plainly worded too rather than dressed as a command's outcome.
  test("questions the user never saw are answered as questions", () async {
    final projected = await project([
      said(MessageRole.assistant, [
        call("a1", askToolName, '{"questions":[]}', response: "r1"),
      ]),
    ]);

    expect(projected.last.text, contains("nothing was answered"));
    expect(projected.last.text, isNot(contains("returncode")));
  });

  test("two calls in one response are answered in order, after it", () async {
    final projected = await project([
      said(MessageRole.assistant, [
        call("c1", "bash", '{"command":"ls"}', response: "r1"),
        ran("c1", "one"),
        call("c2", "bash", '{"command":"pwd"}', response: "r1"),
        ran("c2", "two"),
      ]),
    ]);

    expect(projected.map((m) => m.role),
        [LlmRole.assistant, LlmRole.tool, LlmRole.tool]);
    expect(projected.first.toolCalls.map((c) => c.id), ["c1", "c2"]);
    expect(projected[1].toolCallId, "c1");
    expect(projected[2].toolCallId, "c2");
  });

  test("what the user attached is named and sent", () async {
    final projected = await projectionOf([
      said(MessageRole.user, const [
        MessagePart.file(resource: "r1", filename: "diagram.png", mimeType: "image/png"),
        MessagePart.text(text: "what is this?"),
      ]),
    ], load: (resource) async => Uint8List.fromList([1, 2, 3]));

    expect(projected.single.text,
        userTurnText("what is this?\n\n(attached: diagram.png)", at: at, first: true));
    expect(projected.single.attachments.single.filename, "diagram.png");
    expect(projected.single.attachments.single.mimeType, "image/png");
    expect(projected.single.attachments.single.bytes, [1, 2, 3]);
  });

  test("an image a tool made rides that tool's result", () async {
    final turn = [
      call("c1", "image_generation", '{"prompt":"a cat"}', response: "r1"),
      const MessagePart.file(resource: "cat.png", filename: "image-0.png", mimeType: "image/png"),
      ran("c1", "Generated 1 image(s)"),
      call("c2", "bash", '{"command":"ls"}', response: "r1"),
      ran("c2", "ok"),
    ];
    final cat = LlmAttachment(
        filename: "image-0.png", mimeType: "image/png", bytes: Uint8List.fromList([7]));

    final reloaded = await projectionOf([said(MessageRole.assistant, turn)],
        load: (resource) async => resource == "cat.png" ? cat.bytes : null);
    final live = assistantMessages(turn, files: {"cat.png": cat}).toList();

    for (final projected in [reloaded, live]) {
      final results = projected.where((m) => m.role == LlmRole.tool).toList();
      expect(results.first.attachments, [cat]);
      expect(results.last.attachments, isEmpty);
    }
  });

  // The bytes are gone, the conversation is not: the model is told a file was
  // attached and asked to carry on without it.
  test("an attachment whose resource has gone is left named", () async {
    final projected = await project([
      said(MessageRole.user, const [
        MessagePart.file(resource: "r1", filename: "diagram.png", mimeType: "image/png"),
        MessagePart.text(text: "what is this?"),
      ]),
    ]);

    expect(projected.single.text, contains("(attached: diagram.png)"));
    expect(projected.single.attachments, isEmpty);
  });

  test("an error is the turn's own report, so it is not put back", () async {
    final projected = await project([
      asked("go"),
      said(MessageRole.assistant, const [
        MessagePart.text(text: "started", responseId: "r1"),
        MessagePart.error(message: "the provider gave up"),
      ]),
    ]);

    expect(projected.last.text, "started");
    expect(projected.map((m) => m.text).join(), isNot(contains("gave up")));
  });

  // As the assistant rather than as a tool call: the model never chose this,
  // and reading back a call it did not make is a conversation it disagrees
  // with.
  test("a command the user ran reads back as what the app did for them", () async {
    final projected = await project([
      asked("!echo hello"),
      said(MessageRole.assistant, const [
        MessagePart.shellRun(command: "echo hello", returnCode: 0, output: "hello\n"),
      ]),
    ]);

    expect(projected.map((m) => m.role), [LlmRole.user, LlmRole.assistant]);
    expect(projected.last.toolCalls, isEmpty);
    expect(projected.last.text, contains("echo hello"));
    expect(projected.last.text, contains('"returncode": 0'));
    // Real newlines, not the literal `\n` the text once carried: the
    // transcript is prose the model reads, not an escaped string.
    expect(projected.last.text, contains("me to:\n\necho hello\n\n"));
  });

  test("a message with nothing in it contributes nothing", () async {
    expect(
        await project([asked("   ".trim()), said(MessageRole.assistant, const [])]),
        isEmpty);
  });

  test("an instructions record contributes nothing: the files ride the "
      "per-turn system message", () async {
    final projected = await project([
      asked("go"),
      said(MessageRole.assistant, [
        const MessagePart.instructions(files: [
          InstructionRef(path: "/data/AGENTS.md", kind: InstructionKind.global),
        ]),
        const MessagePart.text(text: "done"),
      ]),
    ]);

    expect(projected, hasLength(2));
    expect(projected.last.role, LlmRole.assistant);
    expect(projected.last.text, "done");
  });

  group("per viewer", () {
    Message authoredReply(String by, [List<MessagePart>? parts]) => Message(
        id: "m${next++}",
        role: MessageRole.assistant,
        createdAt: at,
        parts: parts ?? const [MessagePart.text(text: "the logs say 404")],
        author: by);

    /// A say the room routed: [to] is who it addressed, sigils on as typed.
    Message addressed(String text, List<String> to) => Message(
          id: "m${next++}",
          role: MessageRole.user,
          createdAt: at,
          parts: [MessagePart.text(text: text)],
          addressees: to,
        );

    test("another member's reply reads as a labeled message, not as the viewer's own",
        () async {
      final projected = await project([
        asked("check the logs"),
        authoredReply("@researcher"),
      ], viewer: "reviewer");

      expect(projected.map((m) => m.role), [LlmRole.user, LlmRole.user]);
      expect(projected.last.text, contains("Message from researcher"));
      expect(projected.last.text, contains("not the user"));
      expect(projected.last.text, contains("the logs say 404"));
    });

    test("the viewer's own reply reads as theirs, assistant as always",
        () async {
      final projected = await project([
        asked("check the logs"),
        authoredReply("@reviewer"),
      ], viewer: "reviewer");

      expect(projected.map((m) => m.role), [LlmRole.user, LlmRole.assistant]);
    });

    test("the main agent's unnamed replies reach a member as labeled too",
        () async {
      final projected = await project([
        asked("what happened?"),
        said(MessageRole.assistant, const [MessagePart.text(text: "I looked.")]),
      ], viewer: "researcher");

      expect(projected.map((m) => m.role), [LlmRole.user, LlmRole.user]);
      expect(projected.last.text, isNot(contains("@researcher")));
      // The unnamed reply is the house's — the wording says who wrote it
      // without naming a member handle.
      expect(projected.last.text, contains("another agent"));
    });

    test("a conversation with no authors is worded for the house exactly as before",
        () async {
      final messages = [
        asked("what is 2+2?"),
        said(MessageRole.assistant, const [MessagePart.text(text: "four")]),
      ];
      final forHouse = await project(messages);
      expect(forHouse.map((m) => m.role), [LlmRole.user, LlmRole.assistant]);
      // The house is unnamed and the reply is unnamed: the same viewer, so
      // the reply is the house's own, whatever the date — the wording the
      // cache warms on. `first` rides along unchanged too.
      expect((await project(messages)).map((m) => m.text),
          forHouse.map((m) => m.text));
    });

    test("a peer reply words who it handed to, per viewer", () async {
      final reply = authoredReply("@researcher").copyWith(
          addressees: ["@reviewer", "@writer"]);
      final messages = [asked("check the logs"), reply];

      final forReviewer = await project(messages, viewer: "reviewer");
      expect(forReviewer.last.text, contains("addressed to you and @writer"));
      final forHouse = await project(messages);
      expect(forHouse.last.text,
          contains("addressed to @reviewer, @writer (not to you)"));
      final unrouted = await project(
          [asked("check the logs"), authoredReply("@researcher")],
          viewer: "reviewer");
      expect(unrouted.last.text, isNot(contains("addressed")));
    });

    test("a silent reply reaches no other viewer, and stays its author's",
        () async {
      final silent = authoredReply("@researcher", [
        call("e1", endTurnToolName, '{"reason":"Not for me."}'),
        ran("e1", "Turn ended."),
      ]);
      final messages = [asked("check the logs"), silent];

      expect(await project(messages, viewer: "reviewer"), hasLength(1));
      expect(await project(messages), hasLength(1));
      final own = await project(messages, viewer: "researcher");
      expect(own.last.role, LlmRole.tool);
    });

    test("a peer reply's tool calls do not reach the other viewer", () async {
      final projected = await project([
        asked("check the logs"),
        authoredReply("@researcher", [
          const MessagePart.text(text: "found it"),
          call("c1", "bash", '{"command":"grep"}'),
          ran("c1", "logs"),
        ]),
      ], viewer: "@reviewer");

      expect(projected, hasLength(2));
      expect(projected.last.toolCalls, isEmpty);
      expect(projected.last.text, contains("found it"));
    });

    test("the room's says word who they were addressed to, per viewer",
        () async {
      // A say addressed to the researcher, read by the reviewer: the
      // addressee is on the face of it, and the reviewer's model is not told
      // the user was talking to them.
      final forReviewer = await project([
        addressed("check the logs for @researcher", ["@researcher"]),
        authoredReply("@researcher"),
      ], viewer: "reviewer");
      expect(forReviewer.map((m) => m.role), [LlmRole.user, LlmRole.user]);
      expect(forReviewer.first.text, contains("addressed to @researcher"));
      expect(forReviewer.first.text, isNot(contains("(main agent)")));

      // The addressee's own view: the say is theirs, verbatim.
      final forResearcher = await project([
        addressed("check the logs for @researcher", ["@researcher"]),
      ], viewer: "researcher");
      expect(forResearcher.single.text, contains("check the logs"));
      expect(
          forResearcher.single.text,
          userTurnText("check the logs for @researcher",
              at: at, first: true));

      // The house reads the same say labeled: not its mail.
      final forHouse = await project([
        addressed("check the logs for @researcher", ["@researcher"]),
      ]);
      expect(forHouse.single.text, contains("addressed to @researcher"));
      expect(forHouse.single.text, isNot(userTurnText("check the logs for @researcher", at: at, first: true)));

      // A say the room routed to nobody is the house's mail; a member reading
      // it knows so from the label without a list to name.
      final houseMail = await project([asked("anyone home?")],
          viewer: "researcher");
      expect(houseMail.single.text, contains("addressed to (main agent)"));
    });

    test("the group a say addressed words whole, for a member it left out",
        () async {
      final projected = await project([
        addressed("look into it", const ["@researcher", "@reviewer"]),
      ], viewer: "planner");

      expect(projected.single.text, contains("addressed to @researcher, @reviewer"));
    });

    test("the dress is the viewer's first own mail, not the room's opener",
        () async {
      // The room opened on the house's mail; the reviewer's first own mail
      // came later, and is what their session dresses.
      final forReviewer = await project([
        asked("anyone home?"),
        said(MessageRole.assistant,
            const [MessagePart.text(text: "the house says yes")]),
        addressed("review the diff", ["@reviewer"]),
      ], viewer: "reviewer");

      expect(forReviewer[0].text, contains("addressed to (main agent)"));
      expect(forReviewer[0].text, isNot(contains("The user asks:")));
      expect(forReviewer.last.text,
          userTurnText("review the diff", at: at, first: true));

      // The house's own view dresses the room's opener, its first mail.
      final forHouse = await project([
        asked("anyone home?"),
        said(MessageRole.assistant,
            const [MessagePart.text(text: "the house says yes")]),
        addressed("review the diff", ["@reviewer"]),
      ]);
      expect(forHouse.first.text, userTurnText("anyone home?", at: at, first: true));
      expect(
          forHouse.last.text, contains("addressed to @reviewer"));
      expect(forHouse.last.text, isNot(contains("The user asks:")));

      // And once dressed, a viewer's later mail does not dress again — the
      // dress is once per conversation, per viewer.
      final later = [
        ...[
          asked("anyone home?"),
          said(MessageRole.assistant,
              const [MessagePart.text(text: "yes")]),
          addressed("review the diff", ["@reviewer"]),
          authoredReply("@reviewer"),
          addressed("review it again", ["@reviewer"]),
        ],
      ];
      final dressedOnce = await project(later, viewer: "reviewer");
      expect(dressedOnce[2].text,
          userTurnText("review the diff", at: at, first: true));
      expect(dressedOnce[4].text,
          userTurnText("review it again", at: at, first: false));
    });
  });

  group("compactions", () {
    const marker = ConversationCompaction(
        upToMessageId: "m1", summary: "The user asked things.");

    test("the messages below the boundary are the summary, the rest verbatim",
        () async {
      final projected = await project(
          [
            asked("first"),
            said(MessageRole.assistant, const [MessagePart.text(text: "ok")]),
            asked("second"),
          ],
          first: true,
          compactions: [marker]);

      expect(projected, hasLength(2));
      expect(projected.first.role, LlmRole.user);
      // The boundary message is summarized too: the first thing verbatim is
      // what came after it.
      expect(projected.last.text, contains("second"));
      expect(projected.last.text, isNot(contains("first")));
    });

    test("the marker message is summarized with the rest of its span", () async {
      final first = Message(
          id: "m1",
          role: MessageRole.user,
          createdAt: at,
          parts: const [MessagePart.text(text: "early work")]);
      final projected = await projectionOf(
          [first, asked("later")],
          load: noResources,
          compactions: [marker]);

      // One message where two were, and the attachment bytes the span held
      // are gone with it — the summary is what the model reads.
      expect(projected, hasLength(2));
      expect(projected.first.text, contains("The user asked things."));
    });

    test("the newest marker wins, an earlier one is a shadow", () async {
      final projected = await projectionOf(
          [
            Message(id: "m1", role: MessageRole.user, createdAt: at),
            Message(id: "m2", role: MessageRole.user, createdAt: at),
            asked("third"),
          ],
          load: noResources,
          compactions: [
            const ConversationCompaction(upToMessageId: "m1", summary: "first"),
            const ConversationCompaction(upToMessageId: "m2", summary: "second"),
          ]);

      expect(projected, hasLength(2));
      expect(projected.first.text, contains("second"));
      expect(projected.first.text, isNot(contains("first")));
    });

    test("a marker the projection was not handed is ignored", () async {
      // A fragment — a history that stops short of the boundary — projects
      // the span it was handed whole, which is what makes the slicing of a
      // history safe without knowing where markers sit.
      final projected = await projectionOf([asked("only")],
          load: noResources, compactions: [marker]);

      expect(projected.map((m) => m.text),
          [userTurnText("only", at: at, first: true)]);
    });

    test("the first message after a marker is not dressed as a task", () async {
      final projected = await projectionOf(
          [
            Message(id: "m1", role: MessageRole.user, createdAt: at),
            asked("resumed work"),
          ],
          load: noResources,
          compactions: [marker]);

      expect(projected.last.text, userTurnText("resumed work", at: at, first: true));
    });
  });
}
