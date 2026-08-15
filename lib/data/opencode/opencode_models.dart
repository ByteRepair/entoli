// OpenCode server DTOs. Hand-written from the OpenAPI spec (opencode 1.18.18).
// We only model the fields we use; the full spec is at `GET /doc`.

import "dart:convert";

// === Session ===

class OcSession {
  OcSession({required this.id, this.title, this.directory, this.path});

  final String id;
  final String? title;
  final String? directory;
  final String? path;

  factory OcSession.fromJson(Map<String, dynamic> json) => OcSession(
        id: json["id"] as String,
        title: json["title"] as String?,
        directory: json["directory"] as String?,
        path: json["path"] as String?,
      );
}

// === SSE Events ===

class OcEvent {
  OcEvent({required this.type, required this.properties});
  final String type;
  final Map<String, dynamic> properties;

  factory OcEvent.fromJson(Map<String, dynamic> json) => OcEvent(
        type: json["type"] as String,
        properties: json["properties"] as Map<String, dynamic>? ?? {},
      );
}

/// Parse an SSE stream line-by-line. OpenCode's `/event` endpoint emits
/// `data: {json}\n\n` frames.
Stream<OcEvent> parseSseEvents(Stream<String> lines) {
  return lines
      .where((l) => l.startsWith("data: "))
      .map((l) => l.substring(6))
      .map((data) {
        final json = jsonDecode(data) as Map<String, dynamic>;
        return OcEvent.fromJson(json);
      });
}