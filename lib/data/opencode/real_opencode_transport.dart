// Real transport: spawns a per-chat `opencode serve` process, talks HTTP+SSE.
import "dart:async";

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

  final Map<String, _ChatServer> _servers = {};

  _ChatServer _ensure(String chatId) {
    final s = _servers[chatId];
    if (s == null) throw StateError("Server not started for chat $chatId");
    return s;
  }

  @override
  Future<Uri> ensureServer(String chatId, String workspacePath) async {
    var s = _servers[chatId];
    if (s != null) return s.process.url;
    final proc = await OpencodeProcess.start(
      workingDirectory: workspacePath,
      binary: binary,
      password: password,
      processFactory: processFactory,
    );
    final client = OpencodeClient(baseUrl: proc.url, password: password);
    s = _ChatServer(process: proc, client: client);
    _servers[chatId] = s;
    return proc.url;
  }

  @override
  Future<String> createSession(String chatId, {String? title}) async {
    final s = _ensure(chatId);
    final session = await s.client.createSession(title: title);
    s.sessionId = session.id;
    return session.id;
  }

  @override
  Future<void> promptAsync(String chatId, String sessionId,
      {required String text, String? model, String? provider}) async {
    final s = _ensure(chatId);
    await s.client.promptAsync(sessionId, text: text, model: model, provider: provider);
  }

  @override
  Future<void> abort(String chatId, String sessionId) async {
    final s = _ensure(chatId);
    await s.client.abortSession(sessionId);
  }

  @override
  Future<void> deleteSession(String chatId, String sessionId) async {
    final s = _ensure(chatId);
    await s.client.deleteSession(sessionId);
  }

  @override
  Future<void> injectContext(String chatId, String sessionId, String text) async {
    final s = _ensure(chatId);
    await s.client.injectContext(sessionId, text);
  }

  @override
  Future<void> respondPermission(String chatId, String sessionId, String permissionId, String response) async {
    final s = _ensure(chatId);
    await s.client.respondPermission(sessionId, permissionId, response);
  }

  @override
  Future<Stream<OcEvent>> subscribe(String chatId) {
    final s = _ensure(chatId);
    return s.client.connectEvents();
  }

  @override
  Future<List<Map<String, dynamic>>> providers(String chatId) async {
    final s = _ensure(chatId);
    return s.client.providers();
  }

  @override
  Future<void> dispose(String chatId) async {
    final s = _servers.remove(chatId);
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
  String? sessionId;
}