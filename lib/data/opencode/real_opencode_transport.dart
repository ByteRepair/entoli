// Real transport: spawns a per-chat `opencode serve` process, talks HTTP+SSE.
import "dart:async";

import "../../domain/models.dart";
import "opencode_client.dart";
import "opencode_models.dart";
import "opencode_process.dart";
import "opencode_transport.dart";

class RealOpencodeTransport implements OpencodeTransport {
  RealOpencodeTransport({
    this.binary,
    this.password,
    this.processFactory,
  });

  final String? binary;
  final String? password;
  final ProcessFactory? processFactory;

  /// Keyed on the spawn in flight, not the server it produces. Opening the
  /// composer's menu and sending a message both start one, and a spawn that
  /// lost that race would never reach the map to be stopped again.
  final Map<String, Future<_ChatServer>> _servers = {};

  Future<_ChatServer> _ensure(String chatId) {
    final s = _servers[chatId];
    if (s == null) throw StateError("Server not started for chat $chatId");
    return s;
  }

  @override
  Future<Uri> ensureServer(String chatId, String workspacePath) async {
    final pending = _servers[chatId] ??= _start(workspacePath);
    try {
      return (await pending).process.url;
    } catch (_) {
      // A failed spawn is not worth remembering: the next send should retry.
      if (identical(_servers[chatId], pending)) _servers.remove(chatId);
      rethrow;
    }
  }

  Future<_ChatServer> _start(String workspacePath) async {
    final proc = await OpencodeProcess.start(
      workingDirectory: workspacePath,
      binary: binary,
      password: password,
      processFactory: processFactory,
    );
    return _ChatServer(
      process: proc,
      client: OpencodeClient(baseUrl: proc.url, password: password),
    );
  }

  @override
  Future<String> createSession(String chatId, {String? title}) async {
    final s = await _ensure(chatId);
    return (await s.client.createSession(title: title)).id;
  }

  @override
  Future<void> promptAsync(String chatId, String sessionId,
      {required String text,
      String? model,
      String? provider,
      List<String> agents = const []}) async {
    final s = await _ensure(chatId);
    await s.client
        .promptAsync(sessionId, text: text, model: model, provider: provider, agents: agents);
  }

  @override
  Future<void> runCommand(String chatId, String sessionId,
      {required String name, required String arguments, String? model, String? provider}) async {
    final s = await _ensure(chatId);
    await s.client
        .runCommand(sessionId, name: name, arguments: arguments, model: model, provider: provider);
  }

  @override
  Future<void> abort(String chatId, String sessionId) async {
    final s = await _ensure(chatId);
    await s.client.abortSession(sessionId);
  }

  @override
  Future<void> deleteSession(String chatId, String sessionId) async {
    final s = await _ensure(chatId);
    await s.client.deleteSession(sessionId);
  }

  @override
  Future<void> injectContext(String chatId, String sessionId, String text) async {
    final s = await _ensure(chatId);
    await s.client.injectContext(sessionId, text);
  }

  @override
  Future<void> respondPermission(String chatId, String sessionId, String permissionId, String response) async {
    final s = await _ensure(chatId);
    await s.client.respondPermission(sessionId, permissionId, response);
  }

  @override
  Future<Stream<OcEvent>> subscribe(String chatId) async {
    final s = await _ensure(chatId);
    return s.client.connectEvents();
  }

  @override
  Future<List<Map<String, dynamic>>> providers(String chatId) async {
    final s = await _ensure(chatId);
    return s.client.providers();
  }

  @override
  Future<List<Map<String, dynamic>>> completions(String chatId, CompletionKind kind) async {
    final s = await _ensure(chatId);
    return s.client.completions(kind);
  }

  @override
  Future<void> dispose(String chatId) async {
    final pending = _servers.remove(chatId);
    if (pending == null) return;
    // A spawn still in flight is still stopped; one that failed has nothing to.
    final s = await pending.then<_ChatServer?>((s) => s, onError: (_) => null);
    if (s == null) return;
    await s.client.close();
    await s.process.stop();
  }

  @override
  Future<void> disposeAll() =>
      Future.wait(_servers.keys.toList().map(dispose));
}

class _ChatServer {
  _ChatServer({required this.process, required this.client});
  final OpencodeProcess process;
  final OpencodeClient client;
}