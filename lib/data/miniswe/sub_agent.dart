import "dart:async";

import "../../domain/agent_backend.dart";
import "../../domain/chat_log.dart";
import "../../domain/models.dart";
import "../../domain/permission.dart";
import "../../domain/prompt_library.dart";
import "../../domain/shell.dart";
import "../../domain/sub_agent_log.dart";
import "../../domain/turn_recorder.dart";
import "../../domain/web_search.dart";
import "llm/llm_client.dart";
import "llm/rate_limit_gate.dart";
import "miniswe_agent.dart";
import "projection.dart";

/// Spawns sub-agents for `task` tool calls. Each sub-agent gets a fresh
/// [MinisweSession], the named `@agent`'s body as its system-prompt overlay,
/// and runs to completion headless — no `ask_user`, no `task` (sub-agents do
/// not spawn their own sub-agents), no per-command approval banners. The
/// parent's approval setting gates the parent's own commands; a sub-agent's
/// commands run autonomously, which is what makes a 75-vote fan-out usable.
class SubAgentRunner {
  SubAgentRunner({
    required this.client,
    required this.shell,
    required this.workspace,
    required this.projectWorkspace,
    required this.model,
    required this.library,
    this.options = const MinisweOptions(),
    this.temperature,
    this.reasoningEffort,
    this.webSearch,
    this.rateLimitGate,
    this.log = const NoSubAgentLog(),
  });

  final LlmClient client;
  final Shell shell;
  final String workspace;
  final String projectWorkspace;
  final String model;
  final PromptLibrary? library;
  final MinisweOptions options;
  final double? temperature;
  final String? reasoningEffort;
  final WebSearch? webSearch;

  /// Shared with the parent agent and every sibling sub-agent, so the fan-out
  /// bounds in-flight requests and coordinates 429 backoff as one. Null where
  /// the runner is built directly against a raw client (tests).
  final RateLimitGate? rateLimitGate;

  /// Where each sub-agent's own transcript goes, keyed by the `task` call that
  /// spawned it. Written as it runs, so a sub-agent killed mid-flight leaves
  /// the same half-log a killed conversation does — and the parent can carry it
  /// on rather than lose the work. See [SubAgentLog].
  final SubAgentLog log;

  final Set<MinisweAgent> _active = {};

  /// Run one sub-agent. The [agentName] is looked up in the [library]; a name
  /// that is not found falls back to `general`, and a missing `general` runs
  /// with no overlay. The [prompt] is the sub-agent's whole task — it sees
  /// nothing else of the parent's conversation.
  Future<ShellResult> run(String agentName, String prompt, {String? callId}) async {
    final document = library?.find(CompletionKind.agent, agentName) ??
        library?.find(CompletionKind.agent, "general");
    final agentPrompt = document?.body;

    final session = MinisweSession();
    return _drive(session, agentPrompt, callId,
        (agent) => agent.run(prompt, agentPrompt: agentPrompt));
  }

  /// Carry on the sub-agent [callId] left off in, over a session rebuilt from
  /// its own transcript. The same thing the user's Continue does one level up,
  /// and the same three steps: project the log back, nudge, run the loop.
  Future<ShellResult> resume(String agentName, String callId) async {
    final document = library?.find(CompletionKind.agent, agentName) ??
        library?.find(CompletionKind.agent, "general");
    final agentPrompt = document?.body;

    final session = MinisweSession()..replaceWith(projectionOf(await log.read(callId)));
    return _drive(session, agentPrompt, callId, (agent) => agent.resume(agentPrompt: agentPrompt));
  }

  /// What running and carrying on have in common: the agent, its transcript,
  /// and reading a final answer out of what it said.
  Future<ShellResult> _drive(
    MinisweSession session,
    String? agentPrompt,
    String? callId,
    Stream<AgentEvent> Function(MinisweAgent) start,
  ) async {
    final buffer = StringBuffer();
    String? error;

    final agent = MinisweAgent(
      session: session,
      client: client,
      shell: shell,
      workspace: workspace,
      projectWorkspace: projectWorkspace,
      model: model,
      options: options,
      approveMode: ApproveMode.never,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
      approve: (_) async => ApprovalResponse.allow,
      answer: (_) async => const [],
      offerTaskTool: false,
      offerAskTool: false,
      webSearch: webSearch,
      rateLimitGate: rateLimitGate,
    );
    final recorder = callId == null ? null : await _recorderFor(callId);

    _active.add(agent);
    try {
      await for (final event in start(agent)) {
        recorder?.handle(event);
        switch (event) {
          case TextDelta(:final text):
            buffer.write(text);
          case ErrorEvent(:final message):
            error = message;
          default:
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

    // Text that was in the completion message but never streamed as a delta —
    // the fake client does this, and a provider may too. Read it from the
    // session so nothing the model said is lost.
    if (buffer.isEmpty) {
      for (final message in session.messages) {
        if (message.role == LlmRole.assistant && message.text.isNotEmpty) {
          buffer.write(message.text);
        }
      }
    }

    if (error != null) {
      return ShellResult.failed(error, output: buffer.toString());
    }
    final output = buffer.toString().trim();
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

  /// Cancel every running sub-agent. Called by the parent's [MinisweAgent.cancel].
  Future<void> cancel() async {
    await Future.wait(_active.map((a) => a.cancel()));
    _active.clear();
  }
}