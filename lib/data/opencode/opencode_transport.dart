// Transport abstraction for the opencode server. The real implementation
// spawns a per-chat `opencode serve` process and talks HTTP+SSE. Tests
// inject a fake that yields canned events.
import "dart:async";

import "../../domain/models.dart";
import "opencode_models.dart";

abstract class OpencodeTransport {
  /// Ensure a server is running for [chatId] in the given [workspacePath].
  /// Returns the base URL of the server.
  Future<Uri> ensureServer(String chatId, String workspacePath);

  Future<String> createSession(String chatId, {String? title});

  /// Send a prompt asynchronously (fire-and-forget). Events arrive via
  /// [subscribe]. [agents] are the `@` mentions the message carries.
  Future<void> promptAsync(String chatId, String sessionId,
      {required String text,
      String? model,
      String? provider,
      List<String> agents = const []});

  /// Run a named command. Returns only when the turn it starts is over, so it
  /// must not be awaited before [subscribe] is attached.
  Future<void> runCommand(String chatId, String sessionId,
      {required String name, required String arguments, String? model, String? provider});

  Future<void> abort(String chatId, String sessionId);

  Future<void> deleteSession(String chatId, String sessionId);

  /// Add a message to the session without triggering a reply. Used to seed
  /// a fresh session with the conversation so far.
  Future<void> injectContext(String chatId, String sessionId, String text);

  /// Respond to a permission request.
  Future<void> respondPermission(String chatId, String sessionId, String permissionId, String response);

  /// Subscribe to the SSE event stream for [chatId]. Completes once the
  /// stream is attached, so callers can prompt without racing the events.
  Future<Stream<OcEvent>> subscribe(String chatId);

  Future<List<Map<String, dynamic>>> providers(String chatId);

  Future<List<Map<String, dynamic>>> completions(String chatId, CompletionKind kind);

  Future<void> dispose(String chatId);

  Future<void> disposeAll();
}