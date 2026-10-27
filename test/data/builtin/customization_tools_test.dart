import "dart:convert";

import "package:flutter_test/flutter_test.dart";

import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/tools/customization_tools.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/tools/skill_tool.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/profile.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/domain/tone.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";

void main() {
  group("editedProfile", () {
    const was = Profile(name: "Ada", profession: "Engineer");

    test("changes only the fields passed, and empty clears one", () {
      final edited = editedProfile(
          was, jsonEncode({"religion": "None", "profession": ""}));
      expect(edited.error, isNull);
      expect(edited.profile,
          const Profile(name: "Ada", religion: "None"));
    });

    test("refuses a date that is not YYYY-MM-DD, and an unknown field", () {
      expect(editedProfile(was, jsonEncode({"date_of_birth": "3 May 1990"})).error,
          isNotNull);
      expect(editedProfile(was, jsonEncode({"date_of_birth": "1990-05-03"})).error,
          isNull);
      expect(editedProfile(was, jsonEncode({"age": "30"})).error, isNotNull);
    });
  });

  test("offered only once the session loaded the skill, and they write",
      () async {
    final settings = AppSettings();
    LlmCompletion call(String name, Map<String, String> args) => LlmCompletion(
          message: LlmMessage(role: LlmRole.assistant, toolCalls: [
            LlmToolCall(id: name, name: name, argumentsJson: jsonEncode(args)),
          ]),
        );
    final client = FakeLlmClient([
      [call(skillToolName, {"skill": customizationSkill})],
      [call(setProfileName, {"name": "Ada"})],
      [call(setToneName, {"tone": "kind"})],
      [saidOnly("done")],
    ]);
    await BuiltinAgent(
      session: BuiltinSession(),
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
      skills: [
        PromptDocument(
          kind: CompletionKind.skill,
          name: customizationSkill,
          frontmatter: const {"description": "d"},
          body: "b",
        ),
      ],
      editSettings: (change) async => change(settings),
    ).run(userMessage("set me up")).toList();

    List<String> offered(int i) => client.calls[i].tools.map((t) => t.name).toList();
    expect(offered(0), isNot(contains(setProfileName)));
    expect(offered(1), containsAll([setProfileName, setToneName]));
    expect(settings.profile, const Profile(name: "Ada"));
    expect(settings.tone, Tone.kind);
  });
}
