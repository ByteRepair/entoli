import "dart:convert";
import "dart:typed_data";

import "../../voice/wav.dart";

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
  Future<List<LlmAttachment>> generateImage(
    String prompt, {
    required String model,
    String? quality,
  }) async {
    final parts = await _generate(model, {
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
    });
    final out = <LlmAttachment>[];
    for (final part in parts) {
      final data = part["inlineData"];
      if (data is Map && data["data"] is String && data["mimeType"] is String) {
        final mime = data["mimeType"] as String;
        out.add(
          LlmAttachment(
            filename: "image-${out.length}.${mime.split("/").last}",
            mimeType: mime,
            bytes: base64Decode(data["data"] as String),
          ),
        );
      }
    }
    return out;
  }

  /// Native: the compat surface has no `/audio/transcriptions`. Gemini hears
  /// audio in an ordinary request, so the model is asked to write it down.
  @override
  Future<String> transcribe(Uint8List wav, {required String model}) async {
    final parts = await _generate(model, {
      "contents": [
        {
          "parts": [
            {"text": transcribeInstruction},
            {
              "inlineData": {
                "mimeType": "audio/wav",
                "data": base64Encode(wav),
              },
            },
          ],
        },
      ],
    });
    return [
      for (final part in parts)
        if (part["text"] is String && part["thought"] != true)
          part["text"] as String,
    ].join().trim();
  }

  static const transcribeInstruction =
      "Transcribe this recording verbatim, in the language it is spoken in. "
      "Reply with the transcript alone, or with nothing if no one speaks.";

  /// Native: the compat surface has no `/audio/speech`. What comes back is raw
  /// 16-bit PCM, its rate in the MIME type, so it is wrapped as a WAV here.
  @override
  Future<Uint8List> speak(
    String text, {
    required String model,
    String? voice,
  }) async {
    final parts = await _generate(model, {
      "contents": [
        {
          "parts": [
            {"text": text},
          ],
        },
      ],
      "generationConfig": {
        "responseModalities": ["AUDIO"],
        if (voice != null)
          "speechConfig": {
            "voiceConfig": {
              "prebuiltVoiceConfig": {"voiceName": voice},
            },
          },
      },
    });
    final pcm = BytesBuilder(copy: false);
    var rate = 24000;
    for (final part in parts) {
      final data = part["inlineData"];
      if (data is! Map || data["data"] is! String) continue;
      final mime = data["mimeType"];
      final declared = mime is String ? _rate.firstMatch(mime) : null;
      if (declared != null) rate = int.parse(declared.group(1)!);
      pcm.add(base64Decode(data["data"] as String));
    }
    if (pcm.isEmpty) throw const LlmException("Gemini returned no audio.");
    return wavOfPcm16(pcm.takeBytes(), rate);
  }

  static final _rate = RegExp(r"rate=(\d+)");

  /// Where native `generateContent` lives: one level up from the compat
  /// surface.
  late final Uri _native = baseUrl.replace(
    path: baseUrl.path.replaceFirst(RegExp(r"/openai/?$"), ""),
  );

  /// The parts of the first candidate of a native `generateContent`. Decoded
  /// as it streams, since a spoken sentence is megabytes of base64.
  Future<List<Map<String, dynamic>>> _generate(
    String model,
    Map<String, dynamic> body,
  ) async {
    final response = await postStream(
      httpClient,
      under(_native, "models/$model:generateContent"),
      headers: {"content-type": "application/json", "x-goog-api-key": ?apiKey},
      body: body,
    ).onError<LlmException>((e, _) => throw refused(e));
    final json = await response.stream
        .transform(utf8.decoder.fuse(const JsonDecoder()))
        .first;
    final candidates = json is Map ? json["candidates"] : null;
    final content = candidates is List && candidates.isNotEmpty
        ? (candidates.first as Map)["content"]
        : null;
    final parts = content is Map ? content["parts"] : null;
    return [
      for (final part in parts is List ? parts : const [])
        if (part is Map<String, dynamic>) part,
    ];
  }
}
