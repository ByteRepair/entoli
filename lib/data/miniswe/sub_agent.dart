import "dart:async";

import "../../domain/agent_backend.dart";
import "../../domain/models.dart";
import "../../domain/permission.dart";
import "../../domain/prompt_library.dart";
import "../../domain/shell.dart";
import "../../domain/web_search.dart";
import "llm/llm_client.dart";
import "llm/rate_limit_gate.dart";
import "miniswe_agent.dart";

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

  final Set<MinisweAgent> _active = {};

  /// Run one sub-agent. The [agentName] is looked up in the [library]; a name
  /// that is not found falls back to `general`, and a missing `general` runs
  /// with no overlay. The [prompt] is the sub-agent's whole task — it sees
  /// nothing else of the parent's conversation.
  Future<ShellResult> run(String agentName, String prompt) async {
    final document = library?.find(CompletionKind.agent, agentName) ??
        library?.find(CompletionKind.agent, "general");
    final agentPrompt = document?.body;

    final session = MinisweSession();
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
    _active.add(agent);
    try {
      await for (final event in agent.run(prompt, agentPrompt: agentPrompt)) {
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

  /// Cancel every running sub-agent. Called by the parent's [MinisweAgent.cancel].
  Future<void> cancel() async {
    await Future.wait(_active.map((a) => a.cancel()));
    _active.clear();
  }
}