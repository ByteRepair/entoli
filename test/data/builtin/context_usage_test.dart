import "package:file/local.dart";
import "package:flutter_test/flutter_test.dart";
import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/data/builtin/templates.dart";
import "package:entoli_core/model/agent_backend.dart";
import "package:entoli_core/model/models.dart";
import "package:entoli_core/model/permission.dart";
import "package:entoli_core/model/profile.dart";
import "package:agent_chat/data/builtin/builtin_options.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";

void main() {
  test(
    "every request reports its segments, and the provider's count beside them",
    () async {
      const profile = Profile(name: "Ada", profession: "Engineer");
      final client = FakeLlmClient([
        [
          fileCall("read", {"path": "notes.txt"}),
        ],
        [
          LlmCompletion(
            message: const LlmMessage(role: LlmRole.assistant, text: "done"),
            usage: const LlmUsage(inputTokens: 900, outputTokens: 100),
          ),
        ],
      ]);
      final events = await BuiltinAgent(
        fs: const LocalFileSystem(),
        session: BuiltinSession(),
        client: client,
        shell: FakeShell((_) => ok("")),
        workspace: "/tmp/workspace",
        projectWorkspace: "/tmp/project",
        model: "fake-model",
        options: const BuiltinOptions(),
        approveMode: ApproveMode.never,
        approve: (_) async => ApprovalResponse.allow,
        answer: (request) async => request.unanswered,
        profile: profile,
      ).run(userMessage("hi")).toList();

      final reports = events
          .whereType<ContextEvent>()
          .map((e) => e.usage)
          .toList();
      expect(reports, hasLength(2));
      final first = reports.first;
      expect(first.profile, profileSection(profile).length ~/ 4);
      expect(first.profile, greaterThan(0));
      expect(first.system, greaterThan(first.profile));
      expect(first.tools, greaterThan(0));
      expect(first.reported, isNull);
      // The second request carries the call and its result, and was counted.
      expect(reports.last.chat, greaterThan(first.chat));
      expect(reports.last.reported, 1000);
    },
  );
}
