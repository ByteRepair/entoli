import "dart:io";

import "package:flutter/foundation.dart" show ValueNotifier;
import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/builtin_agent.dart";
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
    bool sandboxReprompt = true,
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

    test("a rerun after the re-prompt records the rerun", () async {
      final client = FakeLlmClient([
        [bashCall("python3 build.py")], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.allow, ApprovalResponse.alwaysAllowChat],
        respond: (_) => const ShellResult(
            returnCode: 1,
            output: "PermissionError: [Errno 13] Permission denied: '/etc/hosts'",
            violations: ["writing /etc/hosts"]),
      ).run(userMessage("go")).toList();
      final result = results(events);
      expect(result.decidedBy, PermissionSource.rerun);
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
    /// A git repository beside the workspace, with the shell standing in it:
    /// the case the grant policy is for — a repo the workspaces do not hold.
    void makeRepo() {
      final repo = p.join(workspaceDir, "..", "repo");
      Directory(p.join(repo, ".git", "objects")).createSync(recursive: true);
      Directory(p.join(repo, ".git", "refs")).createSync();
      Directory(p.join(repo, ".git", "hooks")).createSync();
      File(p.join(repo, ".git", "HEAD")).writeAsStringSync("ref: refs/heads/master\n");
      File(p.join(repo, ".git", "index")).writeAsStringSync("");
      File(p.join(repo, ".git", "config")).writeAsStringSync("[core]\n");
      shell.sessionCwdValue = ValueNotifier(p.normalize(File(repo).path));
    }

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

    test("a vouched git command runs with its repo's .git beside the grant",
        () async {
      final client = FakeLlmClient([
        [bashCall("git commit -m x")], [finish],
      ]);
      // The workspace the harness lays out must exist before makeRepo names
      // the directory beside it.
      final agent = agentOver(
        client,
        approveMode: ApproveMode.never,
        sandboxHelper: _StubHelper(),
      );
      makeRepo();
      final events = await agent.run(userMessage("go")).toList();
      expect(shell.ran, hasLength(1));
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
      final sandbox = shell.sandboxes.last!;
      final repo = p.normalize(p.join(workspaceDir, "..", "repo"));
      // The directory itself: git's transient writes (`index.lock` under a
      // ref-refresh) are new files made in `.git`'s root, and a child-only
      // enumeration cannot cover them.
      expect(sandbox.extraWrites, contains(p.join(repo, ".git")));
      // The decision the result records says what covered it.
      final result = events.whereType<ToolResultEvent>().single.result;
      expect(result.decided, PermissionDecision.allow);
    });

    test("a push stays on the banner path", () async {
      final client = FakeLlmClient([
        [bashCall("git push")], [finish],
      ]);
      final agent = agentOver(client, approveMode: ApproveMode.ask);
      makeRepo();
      final events = await agent.run(userMessage("go")).toList();
      expect(events.whereType<ApprovalRequestEvent>(), hasLength(1));
      // The harness's default answers the banner; what the test pins is that
      // the banner is where the answer comes from, not the parse's vouch.
      expect(shell.ran, hasLength(1));
    });

    test("a read-only git command runs silently and carries the grant too",
        () async {
      // The chat's shape: `git status` refreshes the index (writing
      // `.git/index.lock`), which the sandbox denies unless the grant rides
      // with the read-only tier's allow. Banner-free is the whole point.
      final client = FakeLlmClient([[bashCall("git status && git diff --stat")], [finish]]);
      final agent = agentOver(client, approveMode: ApproveMode.never);
      makeRepo();
      final events = await agent.run(userMessage("go")).toList();
      expect(shell.ran, hasLength(1));
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
      final sandbox = shell.sandboxes.last!;
      final repo = p.normalize(p.join(workspaceDir, "..", "repo"));
      expect(sandbox.extraWrites, contains(p.join(repo, ".git")));
    });

    test("a compound is covered when each of its parts is", () async {
      final client = FakeLlmClient([
        [bashCall("git status && git commit -m x")], [finish],
      ]);
      final agent = agentOver(
        client,
        approveMode: ApproveMode.never,
        sandboxHelper: _StubHelper(),
      );
      makeRepo();
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
      // Distinct ids: the plumbing keys approvals by id, and two banners
      // over one call sharing an id made the second inherit the first's
      // answer and vanish before it was answered.
      expect(approvals.first.approval.id, isNot(approvals.last.approval.id));
    });

    test("a denial that is not a write is rerun confined", () async {
      final client = FakeLlmClient([
        [bashCall("cat /etc/shadow")], [finish],
      ]);
      await agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.allow, ApprovalResponse.allow],
        respond: (_) => const ShellResult(
            returnCode: 1, output: "", violations: ["denied /etc/shadow"]),
      ).run(userMessage("go")).toList();
      expect(shell.ran, hasLength(2));
      expect(shell.sandboxes.whereType<CommandSandbox>(), hasLength(2));
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

    test("the re-prompt's Always widens the grant for the next command",
        () async {
      final client = FakeLlmClient([
        [bashCall("python3 build.py")],
        [bashCall("python3 check.py")], [finish],
      ]);
      final events = await agentOver(
        client,
        approveMode: ApproveMode.ask,
        approvals: [ApprovalResponse.allow, ApprovalResponse.alwaysAllowChat],
        respond: (command) => command == "python3 build.py"
            ? const ShellResult(
                returnCode: 1,
                output:
                    "PermissionError: [Errno 13] Permission denied: '/etc/hosts'",
                violations: ["writing /etc/hosts"])
            : ok("clean"),
      ).run(userMessage("go")).toList();
      // The rerun after the Always answer is unconfined — a write denial is
      // what the human just read and answered. The grant shows on the NEXT
      // command, which runs confined with the denied path beside the
      // workspace: what a persisted grant would arrive as next turn.
      expect(shell.ran,
          ["python3 build.py", "python3 build.py", "python3 check.py"]);
      final sandboxes = shell.sandboxes.whereType<CommandSandbox>().toList();
      expect(sandboxes, hasLength(2));
      expect(sandboxes.first.extraWrites, isNot(contains("/etc/hosts")));
      expect(sandboxes.last.extraWrites, contains("/etc/hosts"));
      // The banner named what it was agreeing to, and the answer carried it.
      // Three banners in all: the ask for build.py, its re-prompt, and the
      // ask for check.py, which runs before any persisted grant is read —
      // the re-prompt's own carries the denied dirs.
      final approvals = events.whereType<ApprovalRequestEvent>().toList();
      expect(approvals, hasLength(3));
      expect(approvals[1].approval.deniedDirs, ["/etc/hosts"]);
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
      // The persisted tier's grant — directories and the file paths a denial
      // report names alike — is what the command's confinement carries.
      expect(shell.sandboxes.single!.extraWrites,
          ["/etc/hosts", "/var/log/entoli"]);
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

/// A classifier that has already made up its mind.
class _StubClassifier implements PermissionClassifier {
  const _StubClassifier(this.decision);

  final PermissionDecision decision;

  @override
  Future<PermissionDecision> classify(String toolName, String argumentsJson,
          {required String workspace}) async =>
      decision;
}

/// A classifier that counts being consulted.
class _SpyClassifier implements PermissionClassifier {
  _SpyClassifier(this.ask);

  final void Function() ask;

  @override
  Future<PermissionDecision> classify(String toolName, String argumentsJson,
          {required String workspace}) async {
    ask();
    return PermissionDecision.allow;
  }
}
