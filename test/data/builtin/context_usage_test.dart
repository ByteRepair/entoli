import "package:flutter_test/flutter_test.dart";

import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/templates.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/profile.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";

void main() {
  test("every request reports its segments, the profile apart from the system",
      () async {
    const profile = Profile(name: "Ada", profession: "Engineer");
    final reports = <ContextUsage>[];
    final client = FakeLlmClient([
      [fileCall("read", {"path": "notes.txt"})],
      [saidOnly("done")],
    ]);
    await BuiltinAgent(
      session: BuiltinSession(),
      client: client,
      shell: FakeShell((_) => ok("")),
      fs: fileSystemIo,
      workspace: "/tmp/workspace",
      projectWorkspace: "/tmp/project",
      model: "fake-model",
      options: const BuiltinOptions(),
      approveMode: ApproveMode.never,
      approve: (_) async => ApprovalResponse.allow,
      answer: (request) async => request.unanswered,
      profile: profile,
      onContext: reports.add,
    ).run(userMessage("hi")).toList();

    expect(reports, hasLength(2));
    final first = reports.first;
    expect(first.profile, profileSection(profile).length ~/ 4);
    expect(first.profile, greaterThan(0));
    expect(first.system, greaterThan(first.profile));
    expect(first.tools, greaterThan(0));
    // The second request carries the call and its result.
    expect(reports.last.chat, greaterThan(first.chat));
  });
}
