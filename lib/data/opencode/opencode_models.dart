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

// === Messages ===

class OcMessageInfo {
  OcMessageInfo({required this.id, required this.role, required this.time, this.modelID, this.providerID});

  final String id;
  final String role; // "user" | "assistant"
  final Map<String, dynamic> time;
  final String? modelID;
  final String? providerID;

  factory OcMessageInfo.fromJson(Map<String, dynamic> json) => OcMessageInfo(
        id: json["id"] as String,
        role: json["role"] as String,
        time: json["time"] as Map<String, dynamic>,
        modelID: json["modelID"] as String?,
        providerID: json["providerID"] as String?,
      );
}

// === Parts (discriminated union on `type`) ===

class OcPart {
  OcPart({required this.type, this.id, this.text, this.tool, this.callID, this.state, this.reason});

  final String type; // text | tool | reasoning | step-start | step-finish | ...
  final String? id;
  final String? text;
  final String? tool;
  final String? callID;
  final Map<String, dynamic>? state;
  final String? reason;

  factory OcPart.fromJson(Map<String, dynamic> json) => OcPart(
        type: json["type"] as String,
        id: json["id"] as String?,
        text: json["text"] as String?,
        tool: json["tool"] as String?,
        callID: json["callID"] as String?,
        state: json["state"] as Map<String, dynamic>?,
        reason: json["reason"] as String?,
      );

  Map<String, dynamic> toJson() => {
        "type": type,
        if (id != null) "id": id,
        if (text != null) "text": text,
        if (tool != null) "tool": tool,
        if (callID != null) "callID": callID,
        if (state != null) "state": state,
        if (reason != null) "reason": reason,
      };
}

class OcMessage {
  OcMessage({required this.info, required this.parts});
  final OcMessageInfo info;
  final List<OcPart> parts;

  factory OcMessage.fromJson(Map<String, dynamic> json) => OcMessage(
        info: OcMessageInfo.fromJson(json["info"] as Map<String, dynamic>),
        parts: (json["parts"] as List).map((p) => OcPart.fromJson(p as Map<String, dynamic>)).toList(),
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