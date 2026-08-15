import "../domain/agent_backend.dart";
import "../domain/models.dart";

/// Runs each chat on the backend it was created with. `state.json` records
/// which one that was, so a chat keeps its runtime across restarts even after
/// the default has been changed under it.
class RoutingBackend implements AgentBackend {
  RoutingBackend({
    required this.backends,
    required this.defaultKind,
    required this.kindOf,
  });

  final Map<BackendKind, AgentBackend> backends;

  /// Read on use, not captured: the settings page retargets it.
  final BackendKind Function() defaultKind;

  /// What [chatId] was created with, from wherever that is recorded. Null for
  /// a chat nothing knows about yet — a brand new one, before it is saved.
  final BackendKind? Function(String chatId) kindOf;

  final Map<String, BackendKind> _cache = {};

  @override
  BackendKind get kind => defaultKind();

  AgentBackend get _default => _backend(defaultKind());

  AgentBackend _backend(BackendKind kind) => backends[kind] ?? backends.values.first;

  AgentBackend _for(String chatId) =>
      _backend(_cache[chatId] ??= kindOf(chatId) ?? defaultKind());

  @override
  Future<Chat> createChat({String? title, String? model, String? provider}) async {
    final chat = await _default.createChat(title: title, model: model, provider: provider);
    _cache[chat.state.id] = chat.state.backend;
    return chat;
  }

  @override
  Stream<AgentEvent> sendPrompt(String chatId, String text,
          {List<Attachment> attachments = const [],
          String? model,
          String? provider,
          bool approveCommands = true}) =>
      _for(chatId).sendPrompt(chatId, text,
          attachments: attachments,
          model: model,
          provider: provider,
          approveCommands: approveCommands);

  @override
  bool honoursApprovals(String chatId) => _for(chatId).honoursApprovals(chatId);

  @override
  Duration stallTimeout(String chatId) => _for(chatId).stallTimeout(chatId);

  @override
  Future<void> abort(String chatId) => _for(chatId).abort(chatId);

  @override
  Future<void> resetSession(String chatId, {List<Message> history = const []}) =>
      _for(chatId).resetSession(chatId, history: history);

  @override
  Future<List<ToolApproval>> pendingApprovals(String chatId) =>
      _for(chatId).pendingApprovals(chatId);

  @override
  Future<void> respondApproval(String chatId, String approvalId, ApprovalResponse response) =>
      _for(chatId).respondApproval(chatId, approvalId, response);

  @override
  Future<void> disposeChat(String chatId) async {
    await _for(chatId).disposeChat(chatId);
    _cache.remove(chatId);
  }

  @override
  Future<void> shutdown() async {
    for (final backend in backends.values) {
      await backend.shutdown();
    }
  }

  /// Every backend's models, the default one's first. They name providers the
  /// same way, so a model both can run appears once; one only a single backend
  /// knows still has to be offered, or a chat on it could never be pointed
  /// anywhere.
  @override
  Future<List<ModelOption>> models() async {
    final preferred = defaultKind();
    final ordered = [preferred, ...backends.keys.where((k) => k != preferred)];
    // Asked at once: with no chat running, opencode's answer means spawning a
    // server, and the harness has no reason to wait behind it.
    final lists = await Future.wait(ordered.map((k) => _backend(k).models()));
    final seen = <String>{};
    return [
      for (final list in lists)
        for (final option in list)
          if (seen.add("${option.providerId}/${option.modelId}")) option,
    ];
  }
}
