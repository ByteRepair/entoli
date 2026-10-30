import "dart:convert";
import "dart:typed_data";

import "package:http/http.dart" as http;

/// An event-stream response carrying [frames], each one already in the shape
/// the provider sends: a map is encoded as JSON, a string goes out as it is
/// (which is how `[DONE]` and a malformed frame are written).
http.StreamedResponse sseResponse(List<Object> frames, {int status = 200}) {
  final body = StringBuffer();
  for (final frame in frames) {
    body.write("data: ${frame is String ? frame : jsonEncode(frame)}\n\n");
  }
  final bytes = utf8.encode(body.toString());
  return http.StreamedResponse(
    Stream.value(bytes),
    status,
    headers: const {"content-type": "text/event-stream"},
  );
}

/// The same, but written as one named event per frame the way Anthropic sends
/// them — the name is repeated in the payload, which is what we actually read.
http.StreamedResponse anthropicSse(List<Map<String, Object?>> events) {
  final body = StringBuffer();
  for (final event in events) {
    body.write("event: ${event["type"]}\ndata: ${jsonEncode(event)}\n\n");
  }
  return http.StreamedResponse(
    Stream.value(utf8.encode(body.toString())),
    200,
    headers: const {"content-type": "text/event-stream"},
  );
}

/// A response that is not an event stream at all, for the failure paths.
http.StreamedResponse errorResponse(int status, Object body) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(body is String ? body : jsonEncode(body))),
      status,
    );

Uint8List bytesOf(List<int> values) => Uint8List.fromList(values);

/// Stands in for a connection that never opened.
class ConnectionRefused implements Exception {
  const ConnectionRefused();

  @override
  String toString() => "Connection refused";
}
