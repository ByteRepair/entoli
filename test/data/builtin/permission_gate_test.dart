import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/templates.dart" show AgentCapabilities;
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/shell.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";

void main() {
  late BuiltinSession session;
  late FakeShell shell;

  /// Where the chat's own workspace is — set by `agentOver` beside `shell`,
  /// so the tests can lay files beside what the agent operates on.
  late String workspaceDir;

  /// The rules the agent's policy reader answers with, live: a test edits
  /// them mid-turn the way a settings page does.
  late List<PermissionRule> liveRules;

  setUp(() => session = BuiltinSession());

  final finish = saidOnly("done");

  /// The [which]'th tool result a turn reported, zero-based — the record the
  /// outcome rides on.
  ToolResult results(List<AgentEvent> events, {int which = 0}) =>
      events.whereType<ToolResultEvent>().toList()[which].result;

  /// The agent under test, carrying [rules]. The rest mirrors `agentOver` in
  /// builtin_agent_test.dart, trimmed to what the rule gate needs.
  BuiltinAgent agentOver(
    FakeLlmClient client, {
    List<PermissionRule> permissions = const [],
    List<String> writableDirs = const [],
    List<ApprovalResponse> approvals = const [],
    ApproveMode approveMode = ApproveMode.never,
    SandboxHelper? sandboxHelper,
    bool sandboxed = true,
    ShellResult Function(String)? respond,
    PermissionClassifier? classifier,
    FakeWebSearch? webSearch,
  }) {
    final tempDir = Directory.systemTemp.createTempSync("agent-gate-test");
    final project = p.join(tempDir.path, "project-ws");
    final chat = p.join(project, "chats", "chat-1");
    Directory(chat).createSync(recursive: true);
    addTearDown(() => tempDir.deleteSync(recursive: true));
    workspaceDir = chat;
    shell = FakeShell(respond ?? (_) => ok(""),
        canRunCommands: true, home: "/home/u");
    final allowed = [...approvals];
    liveRules = [...permissions];
    return BuiltinAgent(
      session: session,
      client: client,
      shell: shell,
      fs: fileSystemIo,
      workspace: chat,
      projectWorkspace: project,
      model: "fake-model",
      approveMode: approveMode,
      approve: (approval) async {
        final answer =
            allowed.isEmpty ? ApprovalResponse.allow : allowed.removeAt(0);
        // What the repository does before an "always" answer reaches the
        // turn: the derived rule is written where the next read finds it.
        if (answer == ApprovalResponse.alwaysAllowChat ||
            answer == ApprovalResponse.alwaysAllowProject) {
          final rule = ruleFromApproval(approval);
          if (rule != null) liveRules.add(rule);
        }
        return answer;
      },
      answer: (request) => Future.value(request.unanswered),
      sandboxHelper: _StubHelper(),
      policy: () async => StandingPermissions(
        permissions: liveRules,
        writableDirs: writableDirs,
        sandboxed: sandboxed,
      ),
      classifier: classifier,
      webSearch: webSearch,
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

    test("a bare command an Always answer covered is not asked again",
        () async {
      // The shape the live run tripped over: the rule an Always answer writes
      // is `npm test *`, and the next call is the bare `npm test` — no
      // arguments, nothing after the pattern's space. The banner must not
      // return for what the user already said always to. `npm test` because
      // the tier must not cover it first: the derivation is what is under
      // test, not the parse's own read-only answer.
      final client = FakeLlmClient([
        [bashCall("npm test")],
        [bashCall("npm test")],
        [bashCall("npm test --watch")], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.alwaysAllowChat],
      ).run(userMessage("go")).toList();
      final requests = events.whereType<ApprovalRequestEvent>().toList();
      expect(requests, hasLength(1),
          reason: "the Always answer covers the bare command and its args");
      expect(shell.ran, ["npm test", "npm test", "npm test --watch"]);
    });

    test("a plain allow is one-shot: the next call asks again", () async {
      final client = FakeLlmClient([
        [bashCall("npm test")],
        [bashCall("npm test")], [finish],
      ]);
      await agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.allow, ApprovalResponse.deny],
      ).run(userMessage("go")).toList();
      // The first ran on the user's one answer; the second waited for the
      // banner again and was denied there.
      expect(shell.ran, ["npm test"]);
    });

    test("a deny on any segment of a compound refuses the whole", () async {
      final client = FakeLlmClient([
        [bashCall("git status && rm -rf build")], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.allow],
        permissions: [
          const PermissionRule(
              tool: "bash",
              pattern: "git status *",
              decision: PermissionDecision.allow),
          const PermissionRule(
              tool: "bash", pattern: "rm *", decision: PermissionDecision.deny),
        ],
      ).run(userMessage("go")).toList();
      final text = events
          .whereType<ToolResultEvent>()
          .map((r) => [r.result.output, r.result.exceptionInfo ?? ""].join(" "))
          .join();
      expect(text, contains("permission rule"));
      expect(shell.ran, isEmpty);
      // No banner: the user's deny is not re-litigated by asking.
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
    });
  });

  group("the recorded outcome", () {
    final allowGit = const PermissionRule(
        tool: "bash",
        pattern: "git status *",
        decision: PermissionDecision.allow,
        origin: PermissionTier.chat);
    final denyRm = const PermissionRule(
        tool: "bash",
        pattern: "rm *",
        decision: PermissionDecision.deny,
        origin: PermissionTier.project);

    test("a rule-allow records the rule and its tier", () async {
      final client = FakeLlmClient([
        [bashCall("git status")], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.ask,
        permissions: [allowGit],
      ).run(userMessage("go")).toList();
      final result = results(events);
      expect(result.decidedBy, PermissionSource.rule);
      expect(result.decidedTier, [PermissionTier.chat]);
    });

    test("a rule-deny records the refusing tier", () async {
      final client = FakeLlmClient([
        [bashCall("rm -rf build")], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.never,
        permissions: [denyRm],
      ).run(userMessage("go")).toList();
      final result = results(events);
      expect(result.decidedBy, PermissionSource.rule);
      expect(result.decidedTier, [PermissionTier.project]);
    });

    test("a compound covered by two tiers records both", () async {
      final client = FakeLlmClient([
        [bashCall("git status && git log --oneline")], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.never,
        permissions: [
          allowGit,
          const PermissionRule(
              tool: "bash",
              pattern: "git log *",
              decision: PermissionDecision.allow,
              origin: PermissionTier.project),
        ],
      ).run(userMessage("go")).toList();
      final result = results(events);
      expect(result.decidedBy, PermissionSource.rule);
      expect(result.decidedTier, [PermissionTier.chat, PermissionTier.project]);
    });

    test("a banner answer records you, once", () async {
      // A command the parse does not cover: the banner is what decided it.
      final client = FakeLlmClient([
        [bashCall("python3 build.py")], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.allow],
      ).run(userMessage("go")).toList();
      final result = results(events);
      expect(result.decidedBy, PermissionSource.human);
      expect(result.decidedTier, [PermissionTier.once]);
    });

    test("never mode records the mode", () async {
      // A command the parse does not cover: `never` is what decides it.
      final client = FakeLlmClient([
        [bashCall("python3 build.py")], [finish],
      ]);
      final events = await agentOver(client, approveMode: ApproveMode.never)
          .run(userMessage("go"))
          .toList();
      final result = results(events);
      expect(result.decidedBy, PermissionSource.mode);
      expect(result.decidedTier, isEmpty);
    });

    test("the classifier records itself", () async {
      // A command the parse does not cover: the classifier decides it.
      final client = FakeLlmClient([
        [bashCall("python3 build.py")], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.auto,
        classifier: _StubClassifier(PermissionDecision.allow),
      ).run(userMessage("go")).toList();
      final result = results(events);
      expect(result.decidedBy, PermissionSource.classifier);
      expect(result.decidedTier, isEmpty);
    });
  });

  group("auto mode", () {
    test("a read the parse proves non-modifying runs silently", () async {
      // The live shape this pins: chat with no rules, app mode auto, the
      // parse rates `git status` non-modifying before any model is asked —
      // the command runs and neither classifier nor banner saw it.
      final client = FakeLlmClient([
        [bashCall("git status")], [finish],
      ]);
      final classifier = FakeClassifier()
        ..decide = (_, _) => PermissionDecision.allow;
      final events = await agentOver(
        client,
        approveMode: ApproveMode.auto,
        classifier: classifier,
      ).run(userMessage("go")).toList();
      expect(shell.ran, ["git status"]);
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
      // The deterministic tier decides before the classifier is paid for.
      expect(classifier.classified, isEmpty);
    });

    // A granted directory is the workspace's own permissions to the sandbox;
    // the classifier, not told, read a write there as one past the workspace
    // and asked.
    test("the classifier is told the project workspace and the grants",
        () async {
      final client = FakeLlmClient([
        [bashCall("make -C /home/u/repo")], [finish],
      ]);
      final classifier = FakeClassifier();
      await agentOver(
        client,
        approveMode: ApproveMode.auto,
        classifier: classifier,
        writableDirs: ["/home/u/repo"],
      ).run(userMessage("go")).toList();

      expect(classifier.alsoWritable.single,
          [p.dirname(p.dirname(workspaceDir)), "/home/u/repo"]);
    });

    test("a denied command is refused, not run", () async {
      final client = FakeLlmClient([
        [bashCall("rm -rf /")], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.auto,
        classifier: FakeClassifier()
          ..decide = (_, _) => PermissionDecision.deny,
      ).run(userMessage("clean")).toList();

      expect(shell.ran, isNot(contains("rm -rf /")));
      expect(results(events).returnCode, -1);
      expect(results(events).exceptionInfo, contains("Denied"));
    });

    test("a write past the workspace the classifier asks escalates", () async {
      final client = FakeLlmClient([
        [bashCall("cp notes.txt /etc/notes-backup")], [finish],
      ]);
      await agentOver(
        client,
        approveMode: ApproveMode.auto,
        approvals: [ApprovalResponse.deny],
        classifier: _StubClassifier(PermissionDecision.ask),
      ).run(userMessage("go")).toList();
      // The classifier's ask reached the banner; the test denied it there.
      expect(shell.ran, isEmpty);

      // The answer rules: an allow runs it after the same banner.
      final allowedClient = FakeLlmClient([
        [bashCall("cp notes.txt /etc/notes-backup")], [finish],
      ]);
      final allowedEvents = await agentOver(
        allowedClient,
        approveMode: ApproveMode.auto,
        approvals: [ApprovalResponse.allow],
        classifier: _StubClassifier(PermissionDecision.ask),
      ).run(userMessage("go")).toList();
      expect(allowedEvents.whereType<ApprovalRequestEvent>().length, 1);
      expect(shell.ran.last, contains("cp notes.txt"));
    });

    test("three consecutive asks pause auto mode for the rest of the turn", () async {
      final client = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                for (final name in ["a", "b", "c", "d"])
                  LlmToolCall(
                      id: name, name: "bash", argumentsJson: '{"command":"$name"}'),
              ],
            ),
          ),
        ],
        [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.auto,
        approvals: List.filled(4, ApprovalResponse.allow),
        classifier: _StubClassifier(PermissionDecision.ask),
      ).run(userMessage("test")).toList();

      expect(events.whereType<InfoEvent>().single.message, contains("Auto mode paused"));
      // All four commands got approval banners; the finish is a text reply,
      // so it is not classified.
      expect(events.whereType<ApprovalRequestEvent>().length, 4);

      // And all allowed instead: the pause has nothing to pause for.
      final allowedClient = FakeLlmClient([
        [
          LlmCompletion(
            message: LlmMessage(
              role: LlmRole.assistant,
              toolCalls: [
                for (final name in ["a", "b", "c", "d"])
                  LlmToolCall(
                      id: name, name: "bash", argumentsJson: '{"command":"$name"}'),
              ],
            ),
          ),
        ],
        [finish],
      ]);
      final allowedEvents = await agentOver(
        allowedClient,
        approveMode: ApproveMode.auto,
        classifier: _StubClassifier(PermissionDecision.allow),
      ).run(userMessage("test")).toList();

      expect(allowedEvents.whereType<InfoEvent>(), isEmpty);
      expect(allowedEvents.whereType<ApprovalRequestEvent>(), isEmpty);
    });

    test("no classifier falls back to asking for every command", () async {
      // A command the parse does not cover: `auto` without a classifier is
      // the fallback that asks — the bare `ls` beside it would run from the
      // deterministic tier.
      final client = FakeLlmClient([
        [bashCall("touch note.txt")], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.auto,
      ).run(userMessage("list")).toList();

      // Only the bash command asks — the finish is a text reply.
      expect(events.whereType<ApprovalRequestEvent>().length, 1);
    });

    test("webfetch goes through the classifier in auto mode", () async {
      final client = FakeLlmClient([
        [fetchCall("https://example.com")],
        [finish],
      ]);
      final web = FakeWebSearch(fetchResult: (_) =>
          const ShellResult(returnCode: 0, output: "page"));
      final events = await agentOver(
        client,
        approveMode: ApproveMode.auto,
        classifier: _StubClassifier(PermissionDecision.deny),
        webSearch: web,
      ).run(userMessage("fetch")).toList();

      expect(web.fetched, isEmpty);
      final result = events.whereType<ToolResultEvent>().first;
      expect(result.result.exceptionInfo, contains("Denied"));
    });

    test("a rule decides ahead of the classifier", () async {
      final client = FakeLlmClient([
        [bashCall("rm -rf build")], [finish],
      ]);
      await agentOver(
        client,
        approveMode: ApproveMode.auto,
        classifier: _StubClassifier(PermissionDecision.allow),
        permissions: [
          const PermissionRule(
              tool: "bash", pattern: "rm *", decision: PermissionDecision.deny),
        ],
      ).run(userMessage("go")).toList();
      // The user's deny outranks whatever the classifier would have said.
      expect(shell.ran, isEmpty);
    });
  });

  group("the deterministic tiers", () {
    test("a read-only command runs without a banner in ask mode", () async {
      final client = FakeLlmClient([
        [bashCall("ls -la")], [finish],
      ]);
      final events = await agentOver(client, approveMode: ApproveMode.ask)
          .run(userMessage("go"))
          .toList();
      expect(shell.ran, ["ls -la"]);
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
    });

    test("an ask rule still shows the read-only command it names", () async {
      final client = FakeLlmClient([
        [bashCall("ls -la")], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.ask,
        permissions: [
          const PermissionRule(
              tool: "bash", pattern: "ls *", decision: PermissionDecision.ask),
        ],
      ).run(userMessage("go")).toList();
      expect(events.whereType<ApprovalRequestEvent>(), hasLength(1),
          reason: "the user's always-show-me outranks the parse's tier");
    });

    test("auto mode never sees the read-only command at all", () async {
      var asked = 0;
      final client = FakeLlmClient([[bashCall("grep -rn x .")], [finish]]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.auto,
        classifier: _SpyClassifier(() => asked++),
      ).run(userMessage("go")).toList();
      expect(shell.ran, hasLength(1));
      expect(asked, 0, reason: "the parse covered it; no classifier call");
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
    });

    test("a push stays on the banner path", () async {
      final client = FakeLlmClient([
        [bashCall("git push")], [finish],
      ]);
      final agent = agentOver(client, approveMode: ApproveMode.ask);
      final events = await agent.run(userMessage("go")).toList();
      expect(events.whereType<ApprovalRequestEvent>(), hasLength(1));
      // The harness's default answers the banner; what the test pins is that
      // the banner is where the answer comes from, not the parse's vouch.
      expect(shell.ran, hasLength(1));
    });

    test("a read-only git command runs without a banner", () async {
      final client = FakeLlmClient([[bashCall("git status && git diff --stat")], [finish]]);
      final agent = agentOver(client, approveMode: ApproveMode.ask);
      final events = await agent.run(userMessage("go")).toList();
      expect(shell.ran, hasLength(1));
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
    });

    test("a fetcher command rides the network rules", () async {
      final client = FakeLlmClient([[bashCall("curl https://example.com")], [finish]]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.ask,
        permissions: [
          const PermissionRule(
              tool: "webfetch", pattern: "*", decision: PermissionDecision.allow),
        ],
        webSearch: FakeWebSearch(),
      ).run(userMessage("go")).toList();
      expect(shell.ran, hasLength(1));
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
    });

    test("a fetcher with no standing answer still asks", () async {
      final client = FakeLlmClient([[bashCall("curl https://example.com")], [finish]]);
      final events = await agentOver(client, approveMode: ApproveMode.ask)
          .run(userMessage("go"))
          .toList();
      // The banner is where the standing answer comes from; the harness's
      // default allows it, and the command runs.
      expect(events.whereType<ApprovalRequestEvent>(), hasLength(1));
      expect(shell.ran, hasLength(1));
    });

    test("a denied domain refuses the fetcher command outright", () async {
      final client = FakeLlmClient(
          [[bashCall("curl https://evil.example/steal")], [finish]]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.ask,
        permissions: [
          const PermissionRule(
              tool: "webfetch",
              pattern: "evil.example",
              decision: PermissionDecision.deny),
        ],
      ).run(userMessage("go")).toList();
      expect(shell.ran, isEmpty);
      final result = results(events);
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("Denied by a permission rule"));
    });
  });

  test("a turn with Landlock off runs nothing confined", () async {
    final client = FakeLlmClient([
      [bashCall("touch /etc/x")], [finish],
    ]);
    await agentOver(client, sandboxed: false).run(userMessage("go")).toList();
    expect(shell.ran, ["touch /etc/x"]);
    expect(shell.sandboxes, [isNull]);
  });

  group("a rule's sandbox", () {
    const unconfinedPodman = PermissionRule(
        tool: "bash", pattern: "podman *", unconfined: true);

    test("an unconfined rule runs its command outside the sandbox", () async {
      final client = FakeLlmClient([
        [bashCall("podman ps")], [finish],
      ]);
      await agentOver(client, permissions: [unconfinedPodman])
          .run(userMessage("go"))
          .toList();
      expect(shell.ran, ["podman ps"]);
      expect(shell.sandboxes, [isNull]);
    });

    test("with no decision of its own, the mode still asks", () async {
      final client = FakeLlmClient([
        [bashCall("podman ps")], [finish],
      ]);
      final events = await agentOver(client,
              approveMode: ApproveMode.ask,
              approvals: [ApprovalResponse.allow],
              permissions: [unconfinedPodman])
          .run(userMessage("go"))
          .toList();
      expect(events.whereType<ApprovalRequestEvent>(), hasLength(1));
      expect(shell.sandboxes, [isNull]);
    });

    test("a segment the rule does not match keeps the run confined",
        () async {
      final client = FakeLlmClient([
        [bashCall("podman ps && touch x")], [finish],
      ]);
      await agentOver(client, permissions: [unconfinedPodman])
          .run(userMessage("go"))
          .toList();
      expect(shell.sandboxes.single, isA<CommandSandbox>());
    });

    test("a rule's writes reach only the commands it matches", () async {
      final client = FakeLlmClient([
        [bashCall("make all")], [bashCall("touch x")], [finish],
      ]);
      await agentOver(client, permissions: [
        const PermissionRule(
            tool: "bash",
            pattern: "make *",
            writes: ["/opt/out"]),
      ]).run(userMessage("go")).toList();
      expect(shell.sandboxes[0]!.extraWrites, contains("/opt/out"));
      expect(shell.sandboxes[1]!.extraWrites, isNot(contains("/opt/out")));
    });

    test("a ~ the user typed is their home by the time the sandbox reads it",
        () async {
      final client = FakeLlmClient([
        [bashCall("podman ps")], [finish],
      ]);
      await agentOver(client, writableDirs: [
        "~/.cache/x",
      ], permissions: [
        const PermissionRule(
            tool: "bash", pattern: "podman *", writes: ["~/.local/share"]),
      ]).run(userMessage("go")).toList();
      expect(shell.sandboxes.single!.extraWrites,
          containsAll(["/home/u/.cache/x", "/home/u/.local/share"]));
      expect(shell.sandboxes.single!.extraWrites.where((w) => w.startsWith("~")),
          isEmpty);
    });

    test("rules saved while a turn runs reach its next command", () async {
      final client = FakeLlmClient([
        [bashCall("podman ps")], [bashCall("podman ps 2>&1 | head -3")],
        [finish],
      ]);
      final agent = agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.allow],
      );
      final events = <AgentEvent>[];
      await for (final event in agent.run(userMessage("go"))) {
        events.add(event);
        // The user adds the rule from settings once the first banner is up.
        if (event is ApprovalRequestEvent) {
          liveRules.add(const PermissionRule(
              tool: "bash",
              pattern: "{podman,toolbox} *",
              decision: PermissionDecision.allow));
        }
      }
      expect(events.whereType<ApprovalRequestEvent>(), hasLength(1),
          reason: "the second call reads the saved rule; its redirect and "
              "read-only pipe change nothing");
      expect(shell.ran, ["podman ps", "podman ps 2>&1 | head -3"]);
    });
  });

  group("leaving the sandbox", () {
    LlmCompletion unsandboxed(String command) =>
        bashCall(command, extra: {"unsandboxed": true});

    test("is asked about, and runs outside the sandbox once allowed",
        () async {
      final client = FakeLlmClient([[unsandboxed("podman ps")], [finish]]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.allow],
      ).run(userMessage("go")).toList();
      final approval = events.whereType<ApprovalRequestEvent>().single.approval;
      expect(approval.unsandboxed, isTrue);
      expect(approval.argumentsText, "podman ps");
      expect(shell.sandboxes, [isNull]);
    });

    test("an allow rule does not cover it; a no-sandbox rule does", () async {
      const allowPodman = PermissionRule(
          tool: "bash", pattern: "podman *", decision: PermissionDecision.allow);
      final client = FakeLlmClient([[unsandboxed("podman ps")], [finish]]);
      var events = await agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.allow],
        permissions: [allowPodman],
      ).run(userMessage("go")).toList();
      expect(events.whereType<ApprovalRequestEvent>(), hasLength(1),
          reason: "allowing a command is not allowing it out of the sandbox");

      final again = FakeLlmClient([[unsandboxed("podman ps 2>&1 | head")], [finish]]);
      events = await agentOver(
        again,
        approveMode: ApproveMode.ask,
        permissions: [
          allowPodman,
          const PermissionRule(
              tool: "bash", pattern: "podman *", unconfined: true),
        ],
      ).run(userMessage("go")).toList();
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
      expect(shell.sandboxes, [isNull]);
    });

    test("auto mode asks the classifier first", () async {
      var asked = 0;
      final client = FakeLlmClient([[unsandboxed("podman ps")], [finish]]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.auto,
        classifier: _SpyClassifier(() => asked++),
      ).run(userMessage("go")).toList();
      expect(asked, 1);
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty,
          reason: "the classifier allowed it");
      expect(shell.sandboxes, [isNull]);
    });

    test("never mode refuses it without a rule", () async {
      final client = FakeLlmClient([[unsandboxed("podman ps")], [finish]]);
      final events = await agentOver(client, approveMode: ApproveMode.never)
          .run(userMessage("go"))
          .toList();
      expect(shell.ran, isEmpty,
          reason: "the sandbox is the one guard an unwatched turn has");
      expect(results(events).exceptionInfo, contains("approval"));
    });

    test("Always writes a no-sandbox rule for the command's words", () async {
      final client = FakeLlmClient([
        [unsandboxed("podman ps")],
        [unsandboxed("podman ps -a")], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.alwaysAllowChat, ApprovalResponse.allow],
      ).run(userMessage("go")).toList();
      expect(liveRules.single.pattern, "podman ps *");
      expect(liveRules.single.unconfined, isTrue);
      expect(liveRules.single.decision, isNull,
          reason: "the asking stays with whatever already decides it");
      // The second call's way out is covered; the command itself is still
      // the mode's to ask about.
      final approvals = events.whereType<ApprovalRequestEvent>().toList();
      expect(approvals, hasLength(2));
      expect(approvals.last.approval.unsandboxed, isFalse);
      expect(shell.sandboxes, [isNull, isNull]);
    });

    test("is offered only where a sandbox is enforced, and never to a "
        "sub-agent", () {
      bool offers(List<LlmTool> tools) =>
          ((tools.firstWhere((t) => t.name == "bash").schema["properties"]
                  as Map)
              .containsKey("unsandboxed"));
      const caps = AgentCapabilities.full;
      expect(offers(agentTools(caps: caps, offerMemory: false, sandboxed: true)),
          isTrue);
      expect(offers(agentTools(caps: caps, offerMemory: false)), isFalse);
      expect(
          offers(agentTools(
              caps: caps, offerMemory: false, sandboxed: true, oneShot: true)),
          isFalse);
    });

    test("the turn's writableDirs reach the sandbox, files included",
        () async {
      final client = FakeLlmClient([
        [bashCall("python3 build.py")], [finish],
      ]);
      await agentOver(
        client,
        approveMode: ApproveMode.never,
        writableDirs: ["/etc/hosts", "/var/log/entoli"],
      ).run(userMessage("go")).toList();
      // The project's workspace, then the persisted tier's grant —
      // directories and files alike — is what the command's confinement
      // carries.
      expect(shell.sandboxes.single!.extraWrites, [
        p.dirname(p.dirname(workspaceDir)),
        "/etc/hosts",
        "/var/log/entoli",
      ]);
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
}

/// A classifier that has already made up its mind.
class _StubClassifier implements PermissionClassifier {
  const _StubClassifier(this.decision);

  final PermissionDecision decision;

  @override
  Future<PermissionDecision> classify(String toolName, String argumentsJson,
          {required String workspace, List<String> alsoWritable = const []}) async =>
      decision;
}

/// A classifier that counts being consulted.
class _SpyClassifier implements PermissionClassifier {
  _SpyClassifier(this.ask);

  final void Function() ask;

  @override
  Future<PermissionDecision> classify(String toolName, String argumentsJson,
          {required String workspace, List<String> alsoWritable = const []}) async {
    ask();
    return PermissionDecision.allow;
  }
}
