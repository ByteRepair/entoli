import "dart:convert";
import "dart:io";

import "permission.dart";

/// A chat's overrides of the app defaults, persisted to `meta.json`. Edited via
/// the chat settings page. Distinct from `state.json` (chat metadata) and
/// `conv.json` (message tree). Null everywhere means "inherit".
class ChatMeta {
  ChatMeta({this.model, this.provider, this.approveMode});

  String? model;
  String? provider;
  ApproveMode? approveMode;

  factory ChatMeta.fromJson(Map<String, dynamic> json) => ChatMeta(
        model: json["model"] as String?,
        provider: json["provider"] as String?,
        approveMode: _approveMode(json),
      );

  factory ChatMeta.fromFile(File file) {
    if (!file.existsSync()) return ChatMeta();
    try {
      return ChatMeta.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
    } catch (_) {
      return ChatMeta();
    }
  }

  /// `approveMode` is the current key. An older file has `approveCommands` as
  /// a bool, migrated by [approveModeFromJson]. Null when neither key is
  /// present, meaning "inherit the app default".
  static ApproveMode? _approveMode(Map<String, dynamic> json) =>
      approveModeFromJson(json);

  Map<String, dynamic> toJson() => {
        if (model != null) "model": model,
        if (provider != null) "provider": provider,
        if (approveMode != null) "approveMode": approveMode!.name,
      };

  Future<void> saveTo(File file) async {
    file.writeAsStringSync(jsonEncode(toJson()));
  }
}
