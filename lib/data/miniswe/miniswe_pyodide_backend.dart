import "package:uuid/uuid.dart";

import "../../core/config.dart";
import "../../core/platform/default_backend.dart";
import "../../domain/agent_backend.dart";
import "../../domain/models.dart";

/// Web backend. Runs mini-swe-agent under Pyodide in a Web Worker.
/// Not yet implemented (phase 9).
class MiniswePyodideBackend implements AgentBackend {
  MiniswePyodideBackend({this.config});

  final AppConfig? config;

  @override
  BackendKind get kind => BackendKind.miniswe;

  @override
  Future<Chat> createChat({String? title, String? model, String? provider}) async {
    final chatId = const Uuid().v4();
    config?.workspaceDir(chatId);
    config?.resourcesDir(chatId);
    final now = DateTime.now();
    return Chat(
      state: ChatState(
        id: chatId,
        title: title ?? "New chat",
        createdAt: now,
        updatedAt: now,
        backend: defaultBackendKind(),
        model: model,
        provider: provider,
      ),
      messages: const [],
    );
  }

  @override
  Stream<AgentEvent> sendPrompt(String chatId, String text,
      {List<Attachment> attachments = const [], String? model, String? provider}) {
    throw UnimplementedError();
  }

  @override
  Future<void> resetSession(String chatId, {String? transcript}) async {}

  @override
  Future<void> abort(String chatId) => throw UnimplementedError();

  @override
  Future<List<ToolApproval>> pendingApprovals(String chatId) async => [];

  @override
  Future<void> respondApproval(String chatId, String approvalId, ApprovalResponse response) {
    throw UnimplementedError();
  }

  @override
  Future<void> disposeChat(String chatId) async {}

  @override
  Future<List<ModelOption>> availableModels() async => [];

  @override
  Future<List<ModelOption>> listModelsStandalone() async => [];
}