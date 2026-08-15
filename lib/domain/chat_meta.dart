import "dart:convert";
import "dart:io";

/// A chat's overrides of the app defaults, persisted to `meta.json`. Edited via
/// the chat settings page. Distinct from `state.json` (chat metadata) and
/// `conv.json` (message tree). Null everywhere means "inherit".
class ChatMeta {
  ChatMeta({this.model, this.provider, this.approveCommands});

  String? model;
  String? provider;
  bool? approveCommands;

  factory ChatMeta.fromFile(File file) {
    if (!file.existsSync()) return ChatMeta();
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return ChatMeta(
        model: json["model"] as String?,
        provider: json["provider"] as String?,
        approveCommands: json["approveCommands"] as bool?,
      );
    } catch (_) {
      return ChatMeta();
    }
  }

  Map<String, dynamic> toJson() => {
        if (model != null) "model": model,
        if (provider != null) "provider": provider,
        if (approveCommands != null) "approveCommands": approveCommands,
      };

  Future<void> saveTo(File file) async {
    file.writeAsStringSync(jsonEncode(toJson()));
  }
}
