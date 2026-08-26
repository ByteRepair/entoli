import "dart:convert";

import "package:flutter_test/flutter_test.dart";

import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/templates.dart";
import "package:agent_chat/data/builtin/skill_tool.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/prompt_library.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";

/// A skill as the library holds one: a body the model is handed whole.
PromptDocument skillDoc(
  String name, {
  String description = "a description",
  bool modelInvocable = true,
  String body = r"Do $ARGUMENTS.",
}) =>
    PromptDocument(
      kind: CompletionKind.skill,
      name: name,
      frontmatter: {
        "description": description,
        if (!modelInvocable) "disable-model-invocation": "true",
      },
      body: body,
    );

void main() {
  late BuiltinSession session;

  setUp(() {
    session = BuiltinSession();
  });

  BuiltinAgent agentWith(FakeLlmClient client, List<PromptDocument> skills) =>
      BuiltinAgent(
        session: session,
        client: client,
        shell: FakeShell((_) => ok(""), canRunCommands: true),
        fs: fileSystemIo,
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        options: const BuiltinOptions(),
        approveMode: ApproveMode.never,
        approve: (_) async => ApprovalResponse.allow,
        answer: (request) async => request.unanswered,
        skills: skills,
      );

  LlmCompletion skillCall(String name, {String? args, String id = "sk-1"}) =>
      LlmCompletion(
        message: LlmMessage(
          role: LlmRole.assistant,
          toolCalls: [
            LlmToolCall(
              id: id,
              name: skillToolName,
              argumentsJson:
                  jsonEncode({"skill": name, "args": ?args}),
            ),
          ],
        ),
      );

  final finish = saidOnly("done");

  group("offering", () {
    test("the skill tool is offered with a model-invocable skill", () async {
      final client = FakeLlmClient([[finish]]);
      await agentWith(client, [skillDoc("review")]).run(userMessage("hi")).toList();

      expect(client.calls.first.tools.map((t) => t.name), contains("skill"));
    });

    test("with no skills, the skill tool is not offered", () async {
      final client = FakeLlmClient([[finish]]);
      await agentWith(client, const []).run(userMessage("hi")).toList();

      expect(client.calls.first.tools.map((t) => t.name), isNot(contains("skill")));
    });

    test("a user-only skill does not turn the skill tool on", () async {
      final client = FakeLlmClient([[finish]]);
      await agentWith(client, [skillDoc("private", modelInvocable: false)])
          .run(userMessage("hi")).toList();

      expect(client.calls.first.tools.map((t) => t.name), isNot(contains("skill")));
    });

    test("the system prompt lists the model-invocable skills, not the rest", () {
      final text = agentSystemMessage(
        platform: "test",
        caps: AgentCapabilities.full,
        skills: [
          skillDoc("review", description: "look it over"),
          skillDoc("private", modelInvocable: false),
        ],
      ).text;

      expect(text, contains("## Skills"));
      expect(text, contains("review: look it over"));
      expect(text, isNot(contains("private")));
    });

    test("no skills leaves the section out of the prompt", () {
      final text =
          agentSystemMessage(platform: "test", caps: AgentCapabilities.full)
              .text;

      expect(text, isNot(contains("## Skills")));
    });
  });

  group("loading", () {
    test("a known skill loads its instructions, arguments substituted", () async {
      final client = FakeLlmClient([
        [skillCall("review", args: "the code")],
        [finish],
      ]);
      final events = await agentWith(client, [skillDoc("review")])
          .run(userMessage("go")).toList();

      final result = events
          .whereType<ToolResultEvent>()
          .firstWhere((e) => e.result.callId == "sk-1")
          .result;
      expect(result.returnCode, 0);
      expect(result.output, "Do the code.");
    });

    test("a skill with no placeholder gets the arguments appended", () async {
      final client = FakeLlmClient([
        [skillCall("brief", args: "for the launch")],
        [finish],
      ]);
      final events =
          await agentWith(client, [skillDoc("brief", body: "Write a brief.")])
              .run(userMessage("go"))
              .toList();

      final result = events
          .whereType<ToolResultEvent>()
          .firstWhere((e) => e.result.callId == "sk-1")
          .result;
      expect(result.returnCode, 0);
      expect(result.output, "Write a brief.\n\nfor the launch");
    });

    test("the tool hands over what a /name message records", () {
      final doc = skillDoc("review");
      final library = PromptLibrary([doc]);
      final text = "/review the code";

      // The composer's `/name` expansion and the `skill` tool are the two
      // routes to a skill's body; the model must read the same words either way.
      expect(
        skillPrompt(doc, "the code"),
        expandedPrompt(text, promptDocuments(text, library)),
      );
    });

    test("an unknown skill is refused, with what is available", () async {
      final client = FakeLlmClient([
        [skillCall("ghost")],
        [finish],
      ]);
      final events =
          await agentWith(client, [skillDoc("review"), skillDoc("brief")])
              .run(userMessage("go"))
              .toList();

      final result = events
          .whereType<ToolResultEvent>()
          .firstWhere((e) => e.result.callId == "sk-1")
          .result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("ghost"));
      expect(result.exceptionInfo, contains("review"));
      expect(result.exceptionInfo, contains("brief"));
    });

    test("with none installed, the refusal says so", () async {
      final client = FakeLlmClient([
        [skillCall("ghost")],
        [finish],
      ]);
      final events = await agentWith(client, const [])
          .run(userMessage("go")).toList();

      final result = events
          .whereType<ToolResultEvent>()
          .firstWhere((e) => e.result.callId == "sk-1")
          .result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("none are installed"));
    });

    test("a user-only skill is refused, not worked around", () async {
      final client = FakeLlmClient([
        [skillCall("private")],
        [finish],
      ]);
      final events =
          await agentWith(client, [skillDoc("private", modelInvocable: false)])
              .run(userMessage("go"))
              .toList();

      final result = events
          .whereType<ToolResultEvent>()
          .firstWhere((e) => e.result.callId == "sk-1")
          .result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("private"));
      expect(result.exceptionInfo, contains("reserved"));
    });

    test("a call with no skill named is a format error", () async {
      final client = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                LlmToolCall(id: "sk-1", name: skillToolName, argumentsJson: '{}'),
              ],
            ),
          ),
        ],
        [finish],
      ]);
      final events =
          await agentWith(client, [skillDoc("review")]).run(userMessage("go")).toList();

      final result = events
          .whereType<ToolResultEvent>()
          .firstWhere((e) => e.result.callId == "sk-1")
          .result;
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains('the "skill" argument was missing'));
    });
  });
}
