import "../../core/config.dart";
import "../../domain/agent_backend.dart";
import "../../domain/models.dart";

/// mini-swe-agent runs in an embedded CPython — Pyodide on the web, Chaquopy
/// on Android. Only the embedding differs, so both share this body until
/// either one is actually implemented.
abstract class MinisweBackend implements AgentBackend {
  MinisweBackend({this.config});

  final AppConfig? config;

  @override
  BackendKind get kind => BackendKind.miniswe;

  @override
  Future<Chat> createChat({String? title, String? model, String? provider}) async =>
      newChat(config, kind: kind, title: title, model: model, provider: provider);

  @override
  Stream<AgentEvent> sendPrompt(String chatId, String text,
          {List<Attachment> attachments = const [], String? model, String? provider}) =>
      throw UnimplementedError();

  @override
  Future<void> abort(String chatId) => throw UnimplementedError();

  @override
  Future<void> respondApproval(String chatId, String approvalId, ApprovalResponse response) =>
      throw UnimplementedError();

  @override
  Future<void> resetSession(String chatId, {List<Message> history = const []}) async {}

  @override
  Future<void> shutdown() async {}

  @override
  Future<List<ToolApproval>> pendingApprovals(String chatId) async => [];

  @override
  Future<void> disposeChat(String chatId) async {}

  @override
  Future<List<ModelOption>> models() async => [];
}
