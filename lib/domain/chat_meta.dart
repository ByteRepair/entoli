import "dart:convert";

import "permission.dart";
import "temp_chat_ttl.dart";

/// A chat's overrides of the app defaults, persisted to `meta.json`. Edited via
/// the chat settings page. Distinct from `state.json` (chat metadata) and
/// `conv.jsonl` (message tree). Null everywhere means "inherit".
class ChatMeta {
  ChatMeta({this.model, this.provider, this.approveMode, this.tempChatTtl});

  String? model;
  String? provider;
  ApproveMode? approveMode;

  /// How long this chat lives once its TTL is enabled. Null means inherit the
  /// project (if set) or app default.
  TempChatTtl? tempChatTtl;

  factory ChatMeta.fromJson(Map<String, dynamic> json) => ChatMeta(
        model: json["model"] as String?,
        provider: json["provider"] as String?,
        approveMode: _approveMode(json),
        tempChatTtl: TempChatTtl.fromNameNullable(json["tempChatTtl"] as String?),
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

  /// The same overrides again, to be edited without the original moving. The
  /// fields are mutable and the settings page writes them in place, so a page
  /// backed out of has to leave what it was handed alone. `AppSettings.copy`
  /// and `ProjectSettings.copy` are the same call for the same reason.
  ChatMeta copy() => ChatMeta(
        model: model,
        provider: provider,
        approveMode: approveMode,
        tempChatTtl: tempChatTtl,
      );

  /// Nothing overridden, so nothing to write down: this chat inherits the
  /// project's answers and the app's, which is what no `meta.json` means.
  bool get isEmpty => toJson().isEmpty;

  Map<String, dynamic> toJson() => {
        if (model != null) "model": model,
        if (provider != null) "provider": provider,
        if (approveMode != null) "approveMode": approveMode!.name,
        if (tempChatTtl != null) "tempChatTtl": tempChatTtl!.name,
      };

  String encode() => jsonEncode(toJson());
}
