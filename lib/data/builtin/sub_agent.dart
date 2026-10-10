import "dart:async";

import "package:fs_shim/fs.dart";

import "../../domain/agent_backend.dart";
import "../../domain/chat_log.dart";
import "../../domain/models.dart";
import "../../domain/permission.dart";
import "../../domain/prompt_library.dart";
import "../../domain/shell.dart";
import "../../domain/sub_agent_log.dart";
import "../../domain/tone.dart";
import "../../domain/turn_recorder.dart";
import "../../domain/web_search.dart";
import "builtin_agent.dart";
import "llm/llm_client.dart";
import "llm/rate_limit_gate.dart";
import "projection.dart";
import "templates.dart";

/// Spawns sub-agents for `task` tool calls — the main agent scheduling
/// delegated participant turns, each with its own [BuiltinSession] and a
/// transcript of its own under `subagents/`. What makes a sub-agent sub is
/// the reply route: it runs to completion headless and never addresses the
/// room — its final text returns as the tool result, readable by the main
/// agent alone. See "Sub-agents" in `AGENTS.md` for the rest.
class SubAgentRunner {
  SubAgentRunner({
    required this.client,
    required this.shell,
    required this.fs,
    required this.workspace,
    required this.projectWorkspace,
    this.environment = const {},
    required this.model,
    required this.library,
    this.options = const BuiltinOptions(),
    this.temperature,
    this.reasoningEffort,
    this.webSearch,
    this.rateLimitGate,
    this.log = const NoSubAgentLog(),
    this.caps = AgentCapabilities.full,
    this.sharedWorkspace = true,
    this.project,
    this.tone = Tone.none,
    this.citations = false,
    this.permissions = const [],
    this.writableDirs = const [],
  });

  final LlmClient client;
  final Shell shell;
  final FileSystem fs;
  final String workspace;
  final String projectWorkspace;
  final Map<String, String> environment;
  final String model;
  final PromptLibrary? library;
  final BuiltinOptions options;
  final double? temperature;
  final String? reasoningEffort;
  final WebSearch? webSearch;

  /// What the parent turn is offered. A sub-agent runs unattended, so it takes
  /// [AgentCapabilities.unattended] of this: no asking, no fanning out, no
  /// publishing — whatever the parent was offered.
  final AgentCapabilities caps;

  /// Whether the project's workspace is shared, so a sub-agent's prompt says
  /// nothing of one where it is not — the parent's [projectWorkspace] is the
  /// chat's own there, and claiming it is shared would be a lie.
  final bool sharedWorkspace;

  /// The turn's rules and writable roots, handed down so a sub-agent's
  /// commands gate the same way. A sub-agent has no banner — nobody is there
  /// to answer one — so only rule-allow and rule-deny reach its commands;
  /// an ask-shaped call is refused.
  final List<PermissionRule> permissions;

  /// What the sub-agent's sandboxed commands may write to beside the
  /// workspace, the parent's grant carried down.
  final List<String> writableDirs;

  /// The project this sub-agent's turn is in, inherited from the parent so the
  /// shell driver resolves the same rootfs instance.
  final String? project;

  /// How the parent's replies are worded, inherited so a worker's part reads
  /// as the same voice the chat is set to.
  final Tone tone;

  /// Whether the parent's turn numbers the web pages it used, inherited the
  /// same way.
  final bool citations;

  /// Shared with the parent agent and every sibling sub-agent, so the fan-out
  /// bounds in-flight requests and coordinates 429 backoff as one. Null where
  /// the runner is built directly against a raw client (tests).
  final RateLimitGate? rateLimitGate;

  /// Where each sub-agent's own transcript goes, keyed by the `task` call that
  /// spawned it. Written as it runs, so a sub-agent killed mid-flight leaves
  /// the same half-log a killed conversation does — and the parent can carry it
  /// on rather than lose the work. See [SubAgentLog].
  final SubAgentLog log;

  final Set<BuiltinAgent> _active = {};

  /// Run one sub-agent. The [agentName] is looked up in the [library]; a name
  /// that is not found falls back to `general`, and a missing `general` runs
  /// with no overlay. The [prompt] is the sub-agent's whole task — it sees
  /// nothing else of the parent's conversation.
  Future<ShellResult> run(String agentName, String prompt, {String? callId}) async {
    final document = library?.find(CompletionKind.agent, agentName) ??
        library?.find(CompletionKind.agent, "general");
    final agentPrompt = document?.body;

    final session = BuiltinSession();
    // The task as a message, because that is what opens a turn now. A
    // sub-agent's transcript opens on the assistant's message, so this one is
    // never logged and has no `/command` of the user's to record.
    final said = unloggedMessage(
        MessageRole.user, DateTime.now(), [MessagePart.text(text: prompt)]);
    return _drive(session, agentPrompt, callId,
        (agent) => agent.run(said, agentPrompt: agentPrompt));
  }

  /// Carry on the sub-agent [callId] left off in, over a session rebuilt from
  /// its own transcript. The same thing the user's Continue does one level up,
  /// and the same three steps: project the log back, nudge, run the loop.
  Future<ShellResult> resume(String agentName, String callId) async {
    final document = library?.find(CompletionKind.agent, agentName) ??
        library?.find(CompletionKind.agent, "general");
    final agentPrompt = document?.body;

    final session = BuiltinSession()
      ..replaceWith(await projectionOf(await log.read(callId), load: noResources));
    return _drive(session, agentPrompt, callId, (agent) => agent.resume(agentPrompt: agentPrompt));
  }

  /// What running and carrying on have in common: the agent, its transcript,
  /// and reading a final answer out of what it said.
  Future<ShellResult> _drive(
    BuiltinSession session,
    String? agentPrompt,
    String? callId,
    Stream<AgentEvent> Function(BuiltinAgent) start,
  ) async {
    String? error;

    final agent = BuiltinAgent(
      session: session,
      client: client,
      shell: shell,
      // One-shot over the same shell: a fresh subshell per command, so the
      // fan-out's commands never share a directory or an environment.
      oneShot: true,
      fs: fs,
      workspace: workspace,
      projectWorkspace: projectWorkspace,
      environment: environment,
      model: model,
      options: options,
      // The same skills the parent sees: a skill's workflow can be a worker's
      // job too, and the skill that drove the fan-out may need reading there.
      skills: library?.entries(CompletionKind.skill) ?? const [],
      approveMode: ApproveMode.never,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
      approve: (_) async => ApprovalResponse.allow,
      answer: (_) async => const [],
      caps: caps.unattended,
      sharedWorkspace: sharedWorkspace,
      project: project,
      tone: tone,
      citations: citations,
      permissions: permissions,
      writableDirs: writableDirs,
      webSearch: webSearch,
      rateLimitGate: rateLimitGate,
    );
    final recorder = callId == null ? null : await _recorderFor(callId);

    _active.add(agent);
    try {
      await for (final event in start(agent)) {
        recorder?.handle(event);
        switch (event) {
          case ErrorEvent(:final message):
            error = message;
          // Named rather than defaulted, so a new event is decided about here
          // too: what a sub-agent hands back is read off the session below, so
          // this watches for the one thing the session cannot say.
          case TextDelta():
          case ReasoningDelta():
          case ReasoningEnd():
          case ResponseStart():
          case ToolCallEvent():
          case ToolResultEvent():
          case ShellRunEvent():
          case ArtifactEvent():
          case SkillInstallEvent():
          case ApprovalRequestEvent():
          case QuestionRequestEvent():
          case SubAgentStartEvent():
          case SubAgentEndEvent():
          case RetryEvent():
          case StatusEvent():
          case ShellOutputEvent():
          case StepLimitEvent():
          case InfoEvent():
          case InstructionsReadEvent():
          case DoneEvent():
            break;
        }
      }
    } catch (e) {
      return ShellResult.failed("$e");
    } finally {
      _active.remove(agent);
      // Closes the transcript with why it ended, so the absence of that record
      // stays the one thing that means the process died mid-turn.
      await recorder?.close();
      recorder?.dispose();
    }

    // **What it said, off the session rather than off the deltas it streamed.**
    // The session is this sub-agent's whole transcript — see "One accumulation"
    // — so a run that was interrupted and carried on answers with both halves,
    // which is what the one `task` call that asked for it is owed.
    //
    // Collecting the deltas instead answered a resumed sub-agent with only the
    // half it said after the interruption, and had a fallback for an empty
    // buffer that reached into the session and so answered with only the half
    // before it. Neither is the answer, and which one you got turned on whether
    // the second half happened to say anything.
    // One line per response, the way `Message.plainText` joins the parts they
    // came from — a response that only called a tool contributes nothing.
    final said = [
      for (final message in session.messages)
        if (message.role == LlmRole.assistant && message.text.isNotEmpty)
          message.text,
    ].join("\n");

    if (error != null) {
      return ShellResult.failed(error, output: said);
    }
    final output = said.trim();
    if (output.isEmpty) {
      return const ShellResult.failed("The sub-agent produced no output.");
    }
    return ShellResult(returnCode: 0, output: output);
  }

  /// The transcript of [callId], open and ready to be added to. A sub-agent's
  /// whole run is one message and it is named after the call, so there is no
  /// second id anywhere and carrying one on adds to what is already there
  /// rather than writing a second message beside it.
  ///
  /// The opening record is written here because nothing else will: the
  /// recorder writes a message's parts, and one level up it is `send` that
  /// lays the message itself down first.
  Future<TurnRecorder> _recorderFor(String callId) async {
    final existing = await log.read(callId);
    final recorder = TurnRecorder(append: (records) => log.append(callId, records));
    if (existing.isEmpty) {
      await recorder.write(recordsOf([
        Message(
          id: callId,
          role: MessageRole.assistant,
          createdAt: DateTime.now(),
          parts: const [],
        ),
      ]));
    }
    recorder.open(callId, existing: existing.lastOrNull?.parts ?? const []);
    return recorder;
  }

  /// Cancel every running sub-agent. Called by the parent's [BuiltinAgent.cancel].
  Future<void> cancel() async {
    await Future.wait(_active.map((a) => a.cancel()));
    _active.clear();
  }
}