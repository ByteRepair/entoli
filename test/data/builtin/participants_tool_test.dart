import "package:flutter_test/flutter_test.dart";

import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/tools/participants_tool.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/prompt_library.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";

/// A member as the library holds one: the frontmatter's description is the
/// short description the roster answers with.
PromptDocument memberDoc(String name, {String? description}) => PromptDocument(
      kind: CompletionKind.agent,
      name: name,
      frontmatter: {"description": ?description},
      body: "You are $name.",
    );

void main() {
  late BuiltinSession session;

  setUp(() => session = BuiltinSession());

  /// The agent over [members] — an omada turn's roster. Null is a direct
  /// turn's, which offers nothing to call. [asked] collects what, if anything,
  /// the turn put behind the banner.
  BuiltinAgent agentWith(
    FakeLlmClient client,
    List<PromptDocument>? members, {
    ApproveMode approveMode = ApproveMode.never,
    List<ToolApproval>? asked,
    String? viewer,
  }) =>
      BuiltinAgent(
        session: session,
        client: client,
        shell: FakeShell((_) => ok("")),
        fs: fileSystemIo,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        options: const BuiltinOptions(),
        approveMode: approveMode,
        approve: (approval) async {
          asked?.add(approval);
          return ApprovalResponse.allow;
        },
        answer: (request) async => request.unanswered,
        roomParticipants: members,
        viewer: viewer,
      );

  final finish = saidOnly("done");

  group("offering", () {
    test("the roster is offered by an omada turn, and by nothing else", () async {
      final room = FakeLlmClient([[finish]]);
      await agentWith(room, [memberDoc("explore")]).run(userMessage("hi")).toList();
      expect(room.calls.first.tools.map((t) => t.name), contains(listParticipantsToolName));

      final direct = FakeLlmClient([[finish]]);
      await agentWith(direct, null).run(userMessage("hi")).toList();
      expect(direct.calls.first.tools.map((t) => t.name),
          isNot(contains(listParticipantsToolName)));
    });
  });

  group("the answer", () {
    test("every member is the handle with the @, then their description",
        () async {
      final client = FakeLlmClient([
        [fileCall(listParticipantsToolName, {})],
        [finish],
      ]);
      final events = await agentWith(client, [
        memberDoc("explore", description: "Fast explorer."),
        memberDoc("general", description: "Your direct answer."),
      ]).run(userMessage("who is here?")).toList();

      final result = events.whereType<ToolResultEvent>().single.result;
      expect(result.returnCode, 0);
      expect(result.output,
          "@explore — Fast explorer.\n@general — Your direct answer.");
    });

    test("a member with no description is the handle alone", () async {
      final client = FakeLlmClient([
        [fileCall(listParticipantsToolName, {})],
        [finish],
      ]);
      final events =
          await agentWith(client, [memberDoc("bare")]).run(userMessage("hi")).toList();

      final result = events.whereType<ToolResultEvent>().single.result;
      expect(result.output, "@bare");
    });

    test("an empty roster answers, it does not fail", () async {
      final client = FakeLlmClient([
        [fileCall(listParticipantsToolName, {})],
        [finish],
      ]);
      final events = await agentWith(client, const []).run(userMessage("hi")).toList();

      final result = events.whereType<ToolResultEvent>().single.result;
      expect(result.returnCode, 0);
      expect(result.output, contains("no members"));
    });

    test("the call and its answer are a pair, unasked", () async {
      // In ask mode, because a read of the room's names is not a call anybody
      // should have to approve.
      final client = FakeLlmClient([
        [fileCall(listParticipantsToolName, {})],
        [finish],
      ]);
      final asked = <ToolApproval>[];
      final events = await agentWith(client, [memberDoc("explore")],
              approveMode: ApproveMode.ask, asked: asked)
          .run(userMessage("hi"))
          .toList();

      expect(events.whereType<ToolCallEvent>().single.call.name,
          listParticipantsToolName);
      expect(events.whereType<ToolResultEvent>().single.result.returnCode, 0);
      expect(asked, isEmpty);
    });
  });

  group("a call where the turn holds no room", () {
    test("is answered unknown tool, not with a roster", () async {
      final client = FakeLlmClient([
        [fileCall(listParticipantsToolName, {})],
        [finish],
      ]);
      final events = await agentWith(client, null).run(userMessage("hi")).toList();

      final result = events.whereType<ToolResultEvent>().first.result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("no tool called '$listParticipantsToolName'"));
    });
  });

  group("end_turn", () {
    test("is offered on a member's turn, not the house's or a direct one",
        () async {
      Future<List<String>> offered(List<PromptDocument>? members,
          {String? viewer}) async {
        final client = FakeLlmClient([[finish]]);
        await agentWith(client, members, viewer: viewer)
            .run(userMessage("hi"))
            .toList();
        return client.calls.first.tools.map((t) => t.name).toList();
      }

      final room = [memberDoc("explore")];
      expect(await offered(room, viewer: "explore"), contains(endTurnToolName));
      expect(await offered(room), isNot(contains(endTurnToolName)));
      expect(await offered(null, viewer: "explore"),
          isNot(contains(endTurnToolName)));
    });

    test("ends the turn without asking the model again", () async {
      final client = FakeLlmClient([
        [fileCall(endTurnToolName, {"reason": "Not for me."})],
        [saidOnly("never asked")],
      ]);
      final events = await agentWith(client, [memberDoc("explore")],
              viewer: "explore")
          .run(userMessage("hi"))
          .toList();

      expect(client.calls, hasLength(1));
      final call = events.whereType<ToolCallEvent>().single.call;
      expect(call.name, endTurnToolName);
      expect(call.argumentsJson, contains("Not for me."));
      expect(events.whereType<TextDelta>(), isEmpty);
      expect(events.last, isA<DoneEvent>());
    });
  });
}
