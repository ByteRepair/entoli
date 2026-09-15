import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/shell.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";

void main() {
  late BuiltinSession session;
  late FakeShell shell;

  setUp(() => session = BuiltinSession());

  final finish = saidOnly("done");

  /// The agent under test, carrying [rules]. The rest mirrors `agentOver` in
  /// builtin_agent_test.dart, trimmed to what the rule gate needs.
  BuiltinAgent agentOver(
    FakeLlmClient client, {
    List<PermissionRule> permissions = const [],
    List<String> writableDirs = const [],
    List<ApprovalResponse> approvals = const [],
    ApproveMode approveMode = ApproveMode.never,
    SandboxHelper? sandboxHelper,
    bool sandboxReprompt = true,
    ShellResult Function(String)? respond,
  }) {
    final tempDir = Directory.systemTemp.createTempSync("agent-gate-test");
    final project = p.join(tempDir.path, "project-ws");
    final chat = p.join(project, "chats", "chat-1");
    Directory(chat).createSync(recursive: true);
    addTearDown(() => tempDir.deleteSync(recursive: true));
    shell = FakeShell(respond ?? (_) => ok(""),
        canRunCommands: true);
    final allowed = [...approvals];
    return BuiltinAgent(
      session: session,
      client: client,
      shell: shell,
      fs: fileSystemIo,
      workspace: chat,
      projectWorkspace: project,
      model: "fake-model",
      approveMode: approveMode,
      approve: (_) async =>
          allowed.isEmpty ? ApprovalResponse.allow : allowed.removeAt(0),
      answer: (request) => Future.value(request.unanswered),
      sandboxHelper: _StubHelper(),
      permissions: permissions,
      writableDirs: writableDirs,
      sandboxReprompt: sandboxReprompt,
    );
  }

  group("permission rules", () {
    test("a rule-allow runs the command without asking", () async {
      final client = FakeLlmClient([
        [bashCall("git status --short")], [finish],
      ]);
      await agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.allow],
        permissions: [
          const PermissionRule(
              tool: "bash",
              pattern: "git status *",
              decision: PermissionDecision.allow),
        ],
      ).run(userMessage("go")).toList();
      expect(shell.ran, ["git status --short"]);
    });

    test("a rule-deny refuses without running or asking", () async {
      final client = FakeLlmClient([
        [bashCall("git push")], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.ask,
        permissions: [
          const PermissionRule(
              tool: "bash", pattern: "git push", decision: PermissionDecision.deny),
        ],
      ).run(userMessage("go")).toList();
      final text = events
          .whereType<ToolResultEvent>()
          .map((r) => [r.result.output, r.result.exceptionInfo ?? ""].join(" "))
          .join();
      expect(text, contains("permission rule"));
      expect(shell.ran, isEmpty);
    });

    test("an uncovered command falls through to the mode: ask waits", () async {
      final client = FakeLlmClient([
        [bashCall("curl example.com")], [finish],
      ]);
      await agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.deny],
        permissions: [
          const PermissionRule(
              tool: "bash", pattern: "git *", decision: PermissionDecision.allow),
        ],
      ).run(userMessage("go")).toList();
      // The banner answered deny: nothing ran.
      expect(shell.ran, isEmpty);
    });

    test("a compound command needs an allow per segment", () async {
      final client = FakeLlmClient([
        [bashCall("git status && curl example.com")], [finish],
      ]);
      await agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.deny],
        permissions: [
          const PermissionRule(
              tool: "bash", pattern: "git status", decision: PermissionDecision.allow),
        ],
      ).run(userMessage("go")).toList();
      // `curl example.com` found no allow: the call went to the banner, which
      // the test denied. The command never ran.
      expect(shell.ran, isEmpty);
    });

    test("a fully-covered compound runs", () async {
      final client = FakeLlmClient([
        [bashCall("git status && git diff --stat")], [finish],
      ]);
      await agentOver(
        client,
        approveMode: ApproveMode.ask,
        permissions: [
          const PermissionRule(
              tool: "bash", pattern: "git *", decision: PermissionDecision.allow),
        ],
      ).run(userMessage("go")).toList();
      expect(shell.ran, hasLength(1));
    });

    test("a rule-allow command the parse cannot model is escalated, not run",
        () async {
      final client = FakeLlmClient([
        [bashCall(r'echo "unclosed')], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.deny],
        permissions: [
          const PermissionRule(
              tool: "bash", pattern: "echo *", decision: PermissionDecision.allow),
        ],
      ).run(userMessage("go")).toList();
      // Escalated to the banner (the test answered deny), never run silently.
      expect(shell.ran, isEmpty);
      expect(events.whereType<ApprovalRequestEvent>(), isNotEmpty);
    });

    test("a rule-allow with findings in never mode is refused", () async {
      final client = FakeLlmClient([
        [bashCall(r'echo "unclosed')], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.never,
        permissions: [
          const PermissionRule(
              tool: "bash", pattern: "echo *", decision: PermissionDecision.allow),
        ],
      ).run(userMessage("go")).toList();
      final text = events
          .whereType<ToolResultEvent>()
          .map((r) => [r.result.output, r.result.exceptionInfo ?? ""].join(" "))
          .join();
      expect(text.toLowerCase(), contains("cannot be checked as one piece"));
      expect(shell.ran, isEmpty);
    });

    test("a runtime rule granted mid-turn covers the next command", () async {
      final client = FakeLlmClient([
        [bashCall("cmd-a")],
        [bashCall("cmd-b")], [finish],
      ]);
      final agent = agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.deny],
      );
      agent.grantRuntimeRule(const PermissionRule(
          tool: "bash", pattern: "cmd-b", decision: PermissionDecision.allow));
      await agent.run(userMessage("go")).toList();
      // The first command waited for the banner and was denied; the second
      // ran on the runtime grant alone.
      expect(shell.ran, ["cmd-b"]);
    });
  });

  group("the sandbox re-prompt", () {
    test("a violating write command is offered back and rerun unconfined",
        () async {
      final client = FakeLlmClient([
        [bashCall("python3 build.py")], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.allow, ApprovalResponse.allow],
        respond: (command) => command == "python3 build.py"
            ? const ShellResult(
                returnCode: 1,
                output: "PermissionError: [Errno 13] Permission denied: '/etc/hosts'",
                violations: ["writing /etc/hosts"])
            : ok("rerun ok"),
      ).run(userMessage("go")).toList();
      expect(shell.ran, hasLength(2),
          reason: "the rerun goes through the banner the user answered");
      // One banner for the run, one for the re-prompt; the second is the
      // one worded by the denial.
      final approvals = events.whereType<ApprovalRequestEvent>().toList();
      expect(approvals, hasLength(2));
      expect(approvals.last.approval.argumentsText, contains("/etc/hosts"));
    });

    test("the re-prompt is gated by the setting", () async {
      final client = FakeLlmClient([
        [bashCall("python3 build.py")], [finish],
      ]);
      await agentOver(
        client,
        approveMode: ApproveMode.never,
        sandboxReprompt: false,
        respond: (_) => const ShellResult(
            returnCode: 1, output: "", violations: ["writing /etc/hosts"]),
      ).run(userMessage("go")).toList();
      expect(shell.ran, hasLength(1), reason: "no rerun without the gate");
    });

    test("the re-prompt is bounded to one per call", () async {
      final client = FakeLlmClient([
        [bashCall("python3 build.py")], [finish],
      ]);
      await agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.allow, ApprovalResponse.deny],
        respond: (_) => const ShellResult(
            returnCode: 1,
            output: "PermissionError: [Errno 13] Permission denied: '/x'",
            violations: ["writing /x"]),
      ).run(userMessage("go")).toList();
      // One rerun at most: the second banner's deny ends it, the denial
      // cannot loop the banner again.
      expect(shell.ran, hasLength(1));
    });
  });

  group("the verbose veto note", () {
    test("a command with a backtick substitution is refused verbosely",
        () async {
      final helper = _StubHelper();
      final client = FakeLlmClient([
        [bashCall("cd ~/Projects/x && echo `evil`")], [finish],
      ]);
      final events = await agentOver(client, sandboxHelper: helper)
          .run(userMessage("go"))
          .toList();
      final text = events
          .whereType<ToolResultEvent>()
          .map((r) => [r.result.output, r.result.exceptionInfo ?? ""].join(" "))
          .join();
      expect(text, contains("a backtick substitution"));
      expect(text, contains("separate bash calls"));
      expect(shell.ran, isEmpty);
    });
  });
}

/// A stub helper so the gate is on, without a kernel in the loop.
class _StubHelper implements SandboxHelper {
  @override
  Future<List<String>?> prefixFor(CommandSandbox sandbox) async =>
      ["/bin/entoli-landlock", "exec", "--workspace", sandbox.workspace, "--"];

  @override
  String? reportPathFor(CommandSandbox sandbox) => null;

  @override
  String? get reportShimPath => null;
}
