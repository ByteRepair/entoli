import "openai_client.dart";

/// Mistral's `/chat/completions`, OpenAI's shape held strictly: a field it
/// does not know is refused with a 422 rather than ignored, and a tool
/// call's id must be nine letters and digits, which one made by another
/// provider earlier in the chat is not.
class MistralClient extends OpenAiClient {
  MistralClient({required super.baseUrl, super.apiKey, super.httpClient});

  static final _ownId = RegExp(r"^[A-Za-z0-9]{9}$");
  static const _digits =
      "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

  /// An id of Mistral's own as it is; any other as nine characters of its
  /// FNV-1a hash, so a call and its result still pair.
  @override
  String callIdOf(String id) {
    if (_ownId.hasMatch(id)) return id;
    var hash = 0xcbf29ce484222325;
    for (final unit in id.codeUnits) {
      hash = (hash ^ unit) * 0x100000001b3;
    }
    final out = StringBuffer();
    for (var i = 0; i < 9; i++) {
      out.write(_digits[(hash >>> (i * 6)) % _digits.length]);
    }
    return "$out";
  }

  /// Usage comes on the last frame unasked, and `stream_options` is a field
  /// it does not know. Its effort is low, medium or high.
  @override
  Map<String, dynamic> shaped(Map<String, dynamic> body) {
    final effort = switch (body["reasoning_effort"]) {
      "minimal" || "low" => "low",
      "medium" => "medium",
      "high" || "xhigh" || "max" => "high",
      _ => null,
    };
    return {
      for (final MapEntry(:key, :value) in body.entries)
        if (key != "stream_options" && key != "reasoning_effort") key: value,
      "reasoning_effort": ?effort,
    };
  }
}
