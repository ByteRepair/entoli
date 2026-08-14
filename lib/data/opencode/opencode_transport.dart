// Transport abstraction for the opencode server. The real implementation
// spawns a per-chat `opencode serve` process and talks HTTP+SSE. Tests
// inject a fake that yields canned events.
import "dart:async";

import "opencode_models.dart";

abstract class OpencodeTransport {
  /// Ensure a server is running for [chatId] in the given [workspacePath].
  /// Returns the base URL of the server.
  Future<Uri> ensureServer(String chatId, String workspacePath);

  /// Create a new session. Returns the session ID.
  Future<String> createSession(String chatId, {String? title});

  /// Send a prompt asynchronously (fire-and-forget). Events arrive via
  /// [subscribe].
  Future<void> promptAsync(String chatId, String sessionId,
      {required String text, String? model, String? provider});

  /// Abort the running turn for a session.
  Future<void> abort(String chatId, String sessionId);

  /// Delete a session.
  Future<void> deleteSession(String chatId, String sessionId);

  /// Add a message to the session without triggering a reply. Used to seed
  /// a fresh session with the conversation so far.
  Future<void> injectContext(String chatId, String sessionId, String text);

  /// Respond to a permission request.
  Future<void> respondPermission(String chatId, String sessionId, String permissionId, String response);

  /// Subscribe to the SSE event stream for [chatId]. Completes once the
  /// stream is attached, so callers can prompt without racing the events.
  Future<Stream<OcEvent>> subscribe(String chatId);

  /// List available providers/models.
  Future<List<Map<String, dynamic>>> providers(String chatId);

  /// Stop the server for [chatId] and release resources.
  Future<void> dispose(String chatId);

  /// Stop every server this transport started.
  Future<void> disposeAll();
}