import "dart:convert";
import "dart:io";

/// Per-chat LLM parameters, persisted to `meta.json`. Edited via the chat
/// settings page. Distinct from `state.json` (chat metadata) and `conv.json`
/// (message tree): this holds generation-time knobs.
class ChatMeta {
  ChatMeta({
    this.model,
    this.provider,
    this.temperature,
    this.reasoningEffort,
  });

  String? model;
  String? provider;
  double? temperature;
  String? reasoningEffort;

  factory ChatMeta.fromFile(File file) {
    if (!file.existsSync()) return ChatMeta();
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return ChatMeta(
        model: json["model"] as String?,
        provider: json["provider"] as String?,
        temperature: (json["temperature"] as num?)?.toDouble(),
        reasoningEffort: json["reasoningEffort"] as String?,
      );
    } catch (_) {
      return ChatMeta();
    }
  }

  Map<String, dynamic> toJson() => {
    if (model != null) "model": model,
    if (provider != null) "provider": provider,
    if (temperature != null) "temperature": temperature,
    if (reasoningEffort != null) "reasoningEffort": reasoningEffort,
  };

  Future<void> saveTo(File file) async {
    file.writeAsStringSync(jsonEncode(toJson()));
  }
}