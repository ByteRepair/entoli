import "dart:convert";

import "permission.dart";

/// A chat's overrides of the app defaults, persisted to `meta.json`. Edited via
/// the chat settings page. Distinct from `state.json` (chat metadata) and
/// `conv.jsonl` (message tree). Null everywhere means "inherit".
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

  /// Null is a `meta.json` that was never written, which inherits everything —
  /// and so is one that cannot be parsed.
  factory ChatMeta.parse(String? text) {
    if (text == null) return ChatMeta();
    try {
      return ChatMeta.fromJson(jsonDecode(text) as Map<String, dynamic>);
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

  String encode() => jsonEncode(toJson());
}
