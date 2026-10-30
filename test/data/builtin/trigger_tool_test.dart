import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/tools/trigger_tool.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/domain/trigger.dart";
import "package:agent_chat/domain/trigger_manager.dart";

import "../../fakes.dart";
import "builtin_fakes.dart";

/// The registration the tools ran against, recording what landed.
class FakeRegistry implements TriggerRegistry {
  final stored = <Trigger>[];
  final removed = <String>[];

  String? chatId;

  PromptLibrary? library;

  @override
  Future<Trigger> register({
    required TriggerSource source,
    required String prompt,
    String? name,
    String? member,
  }) async {
    if (member case final name?
        when (library ?? PromptLibrary.empty).find(
              CompletionKind.agent,
              name,
            ) ==
            null) {
      throw ArgumentError.value(member, "member", "no agent named $member");
    }
    final id = "t-${stored.length + 1}";
    // The same anchor the provider's own registerFor applies: a timer is
    // re-dated to the moment of registration, the parse's placeholder gone.
    final now = DateTime(2026, 8, 23, 9);
    final anchored = source is TimerSource
        ? TimerSource(duration: source.duration, registeredAt: now)
        : source;
    // And the same refusal, at the same site — the tools' story runs it.
    final problem = triggerScheduleProblem(anchored, now);
    if (problem != null) {
      throw ArgumentError.value((anchored as ScheduleSource).at, "at", problem);
    }
    final trigger = Trigger(
      id: id,
      name: name ?? "",
      prompt: prompt,
      source: anchored,
      chatId: chatId,
      member: member,
      byAgent: true,
      nextFireAt: anchored.nextAfter(now),
    );
    stored.add(trigger);
    return trigger;
  }

  @override
  Future<List<Trigger>> own() async => [
    for (final t in stored)
      if (t.chatId == chatId) t,
  ];

  @override
  Future<void> remove(String id) async => removed.add(id);
}

final _finish = saidOnly("done");

void main() {
  late FakeRegistry registry;
  late Directory tempDir;

  setUp(() {
    registry = FakeRegistry()
      ..chatId = "chat-1"
      // What the room composes against: the test library's two agents.
      ..library = testLibrary();
    tempDir = Directory.systemTemp.createTempSync("trigger-tool-test");
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// The agent with the register wired, and the model's two step replies
  /// scripted: the tool call, then the finish.
  BuiltinAgent agent(List<LlmCompletion> script, {TriggerRegistry? over}) {
    final client = FakeLlmClient([
      script,
      [_finish],
    ]);
    final projectWorkspace = p.join(tempDir.path, "project");
    final workspace = p.join(projectWorkspace, "chats", "chat-1");
    Directory(workspace).createSync(recursive: true);
    return BuiltinAgent(
      session: BuiltinSession(),
      client: client,
      shell: FakeShell((_) => ok("")),
      workspace: workspace,
      projectWorkspace: projectWorkspace,
      model: "fake-model",
      approve: (_) async => ApprovalResponse.allow,
      answer: (request) async => request.unanswered,
      registerTrigger: over ?? registry,
    );
  }

  ToolResult resultOf(List<AgentEvent> events) =>
      events.whereType<ToolResultEvent>().single.result;

  test("trigger_set registers a one-shot schedule into this chat", () async {
    final events = await agent([
      fileCall(triggerSetName, {
        "source": "schedule",
        "prompt": "check the build",
        "at": "2026-08-24T09:00:00",
      }),
    ]).run(userMessage("remind me tomorrow")).toList();

    final stored = registry.stored.single;
    expect(stored.chatId, "chat-1");
    expect(stored.byAgent, isTrue);
    final source = stored.source as ScheduleSource;
    expect(source.at, DateTime(2026, 8, 24, 9));
    expect(source.repeat, ScheduleRepeat.off);
    // The result names the id and the next fire.
    expect(resultOf(events).output, contains("t-1"));
  });

  test("trigger_set registers a timer", () async {
    await agent([
      fileCall(triggerSetName, {
        "source": "timer",
        "prompt": "pick this up",
        "seconds": 30,
      }),
    ]).run(userMessage("go")).toList();

    final timer = registry.stored.single.source as TimerSource;
    expect(timer.duration, const Duration(seconds: 30));
    // Armed against a now the registry chose: a fire time inside the
    // countdown's reach of it.
    expect(registry.stored.single.nextFireAt, isNotNull);
  });

  test("trigger_set registers a file watch", () async {
    await agent([
      fileCall(triggerSetName, {
        "source": "file",
        "prompt": "report",
        "paths": ["build.log"],
        "events": ["change"],
        "cooldownSeconds": 60,
      }),
    ]).run(userMessage("watch it")).toList();

    final file = registry.stored.single.source as FileSource;
    expect(file.paths, ["build.log"]);
    expect(file.events, {FileEvent.change});
    expect(file.cooldown, const Duration(seconds: 60));
    // Nothing on the clock to arm.
    expect(registry.stored.single.nextFireAt, isNull);
  });

  test("trigger_set refuses what is missing, naming what was wanted", () async {
    final events = await agent([
      fileCall(triggerSetName, {"source": "timer", "prompt": "x"}),
    ]).run(userMessage("go")).toList();

    final result = resultOf(events);
    expect(result.returnCode, -1);
    expect(result.exceptionInfo, contains(triggerSetProblem("timer")));
  });

  test("trigger_set stores the member it was given", () async {
    final events = await agent([
      fileCall(triggerSetName, {
        "source": "schedule",
        "prompt": "triage the bugs",
        "at": "2026-08-24T09:00:00",
        "member": "explore",
      }),
    ]).run(userMessage("hand it to explore")).toList();

    expect(registry.stored.single.member, "explore");
    final result = resultOf(events);
    expect(result.returnCode, 0);
    expect(result.output, contains("@explore"));
  });

  test("trigger_set refuses a member the project does not hold", () async {
    // The setUp library holds explore and build only — nobody is not one.
    final events = await agent([
      fileCall(triggerSetName, {
        "source": "schedule",
        "prompt": "triage the bugs",
        "at": "2026-08-24T09:00:00",
        "member": "nobody",
      }),
    ]).run(userMessage("hand it to nobody")).toList();

    final result = resultOf(events);
    expect(result.returnCode, -1);
    expect(result.exceptionInfo, contains("nobody"));
    expect(registry.stored, isEmpty);
  });

  test(
    "trigger_set refuses a one-shot already past, as a fixable error",
    () async {
      final events = await agent([
        fileCall(triggerSetName, {
          "source": "schedule",
          "prompt": "p",
          "at": "2026-08-22T09:00:00",
        }),
      ]).run(userMessage("remind me")).toList();

      final result = resultOf(events);
      expect(result.returnCode, -1);
      expect(result.exceptionInfo, contains("could not be set"));
      expect(result.exceptionInfo, contains("never fire"));
      expect(registry.stored, isEmpty);
    },
  );

  test("trigger_list names the member a fire is addressed to", () async {
    await registry.register(
      source: ScheduleSource(at: DateTime(2026, 8, 24, 9)),
      prompt: "p",
      member: "build",
    );
    final events = await agent([
      fileCall(triggerListName, {}),
    ]).run(userMessage("what is armed?")).toList();
    final output = resultOf(events).output;
    expect(output, contains("t-1"));
    expect(output, contains("@build"));
  });

  test(
    "trigger_list answers this chat's own with ids and next fires",
    () async {
      await registry.register(
        source: ScheduleSource(at: DateTime(2026, 8, 24, 9)),
        prompt: "p",
        name: "sweep",
      );
      final events = await agent([
        fileCall(triggerListName, {}),
      ]).run(userMessage("what is armed?")).toList();
      final output = resultOf(events).output;
      expect(output, contains("t-1"));
      expect(output, contains("sweep"));
    },
  );

  test("trigger_remove takes this chat's own, and only those", () async {
    await registry.register(
      source: ScheduleSource(at: DateTime(2026, 8, 24, 9)),
      prompt: "p",
    );
    final first = agent([
      fileCall(triggerRemoveName, {"id": "t-1"}),
    ]);
    await first.run(userMessage("drop it")).toList();
    expect(registry.removed, ["t-1"]);

    registry.stored.add(
      Trigger(
        id: "t-9",
        name: "n",
        prompt: "p",
        // Another chat's: not this registry's to remove.
        source: ScheduleSource(at: DateTime(2026)),
        chatId: "chat-2",
        byAgent: true,
      ),
    );
    final stranger = agent([
      fileCall(triggerRemoveName, {"id": "t-9"}),
    ]);
    final events = await stranger.run(userMessage("drop it")).toList();
    expect(registry.removed, ["t-1"]);
    expect(resultOf(events).exceptionInfo, contains("registered by this chat"));
  });

  test("a turn without the registry is offered the trio nowhere", () async {
    final client = FakeLlmClient([
      [_finish],
    ]);
    final bare = BuiltinAgent(
      session: BuiltinSession(),
      client: client,
      shell: FakeShell((_) => ok("")),
      workspace: tempDir.path,
      projectWorkspace: tempDir.path,
      model: "fake-model",
      approve: (_) async => ApprovalResponse.allow,
      answer: (request) async => request.unanswered,
    );
    await bare.run(userMessage("go")).toList();

    // The schema the model was sent carried no trigger tool.
    final tools = client.calls.single.tools.map((t) => t.name);
    expect(tools, isNot(contains(triggerSetName)));
  });
}
