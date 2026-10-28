import "dart:convert";

import "http_stream.dart";
import "llm_client.dart";
import "openai_client.dart";

/// Gemini through its OpenAI-compatible surface, and where that surface is not
/// enough.
class GeminiClient extends OpenAiClient {
  GeminiClient({required super.baseUrl, super.apiKey, super.httpClient});

  static const retired =
      "Google has retired this model, please select a newer model.";

  /// By status alone: the wording is Google's to change.
  @override
  LlmException refused(LlmException e) =>
      e.statusCode == 404 ? const LlmException(retired) : e;

  /// Gemini signs the first call of a reply and refuses the reply back
  /// unsigned. One with none — logged before signatures were kept, or made by
  /// another model — gets this instead.
  // shortcut: the placeholder is LiteLLM's, not in Google's docs; replace it
  // if Google documents one or stops taking it.
  @override
  String? get unsignedCallSignature => "skip_thought_signature_validator";

  /// Native, because neither compat route takes every Gemini image model.
  @override
  Future<List<LlmAttachment>> generateImage(String prompt,
      {required String model, String? quality}) async {
    final native = baseUrl.replace(
        path: baseUrl.path.replaceFirst(RegExp(r"/openai/?$"), ""));
    final response = await postStream(
      httpClient,
      under(native, "models/$model:generateContent"),
      headers: {"content-type": "application/json", "x-goog-api-key": ?apiKey},
      body: {
        "contents": [
          {
            "parts": [
              {"text": prompt},
            ],
          },
        ],
        "generationConfig": {
          "responseModalities": ["TEXT", "IMAGE"],
        },
      },
    );
    final json = jsonDecode(await response.stream.bytesToString());
    final candidates = json is Map ? json["candidates"] : null;
    final content = candidates is List && candidates.isNotEmpty
        ? (candidates.first as Map)["content"]
        : null;
    final parts = content is Map ? content["parts"] : null;
    final out = <LlmAttachment>[];
    for (final part in parts is List ? parts : const []) {
      final data = part is Map ? part["inlineData"] : null;
      if (data is Map && data["data"] is String && data["mimeType"] is String) {
        final mime = data["mimeType"] as String;
        out.add(LlmAttachment(
          filename: "image-${out.length}.${mime.split("/").last}",
          mimeType: mime,
          bytes: base64Decode(data["data"] as String),
        ));
      }
    }
    return out;
  }
}
