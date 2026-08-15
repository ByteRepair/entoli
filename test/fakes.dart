import "dart:async";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";

/// Two providers, two models each, deliberately not in alphabetical order so
/// tests can assert the UI sorts them.
const testModels = [
  ModelOption(providerId: "ollama-cloud", modelId: "llama-3", label: "Llama 3"),
  ModelOption(providerId: "ollama-cloud", modelId: "qwen-2.5", label: "Qwen 2.5"),
  ModelOption(providerId: "anthropic", modelId: "claude-sonnet-4", label: "Claude Sonnet 4"),
  ModelOption(providerId: "anthropic", modelId: "claude-haiku-3", label: "Claude Haiku 3"),
];

/// Two names sharing a prefix, so tests can assert the menu filters.
const testCommands = [
  CompletionOption(name: "init", description: "guided AGENTS.md setup"),
  CompletionOption(name: "review", description: "review changes"),
  CompletionOption(name: "revert", description: "undo the last turn"),
];

const testAgents = [
  CompletionOption(name: "build", description: "the default agent"),
  CompletionOption(name: "explore", description: "fast codebase search"),
];

class FakeBackend implements AgentBackend {
  @override
  BackendKind get kind => BackendKind.opencode;

  var _created = 0;

  @override
  Future<Chat> createChat({String? title, String? model, String? provider}) async {
    final now = DateTime.now();
    return Chat(
      state: ChatState(
        id: "fake-${++_created}",
        title: title ?? "New chat",
        createdAt: now,
        updatedAt: now,
        backend: BackendKind.opencode,
        model: model,
        provider: provider,
      ),
    );
  }

  final List<({String text, String? model, String? provider})> prompts = [];

  /// What the next turn streams back. Defaults to an immediate, empty reply.
  List<AgentEvent> scriptedEvents = const [DoneEvent()];

  /// When set, the turn stays open after the scripted events, the way a real
  /// one does while the backend is still working.
  Completer<void>? hold;

  @override
  Stream<AgentEvent> sendPrompt(String chatId, String text,
      {List<Attachment> attachments = const [], String? model, String? provider}) async* {
    prompts.add((text: text, model: model, provider: provider));
    yield* Stream.fromIterable(scriptedEvents);
    if (hold != null) await hold!.future;
  }

  final List<List<Message>> resets = [];

  @override
  Future<void> resetSession(String chatId, {List<Message> history = const []}) async {
    resets.add(history);
  }

  var didShutdown = false;

  @override
  Future<void> shutdown() async => didShutdown = true;

  final List<String> aborted = [];

  @override
  Future<void> abort(String chatId) async {
    aborted.add(chatId);
  }

  @override
  Future<List<ToolApproval>> pendingApprovals(String chatId) async => [];

  @override
  Future<void> respondApproval(String chatId, String approvalId, ApprovalResponse response) async {}

  @override
  Future<void> disposeChat(String chatId) async {}

  @override
  Future<List<ModelOption>> models() async => testModels;

  Map<CompletionKind, List<CompletionOption>> scriptedCompletions = {
    CompletionKind.command: testCommands,
    CompletionKind.agent: testAgents,
  };

  /// Held open, the menu is left in its loading state.
  Completer<void>? holdCompletions;

  @override
  Future<List<CompletionOption>> completions(String chatId, CompletionKind kind) async {
    await holdCompletions?.future;
    return scriptedCompletions[kind] ?? const [];
  }
}
