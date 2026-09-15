import "dart:convert";

import "permission.dart";
import "temp_chat_ttl.dart";

/// A chat's overrides of the app defaults, persisted to `meta.json`. Edited via
/// the chat settings page. Distinct from `state.json` (chat metadata) and
/// `conv.jsonl` (message tree). Null everywhere means "inherit".
class ChatMeta {
  ChatMeta(
      {this.model,
      this.provider,
      this.approveMode,
      this.tempChatTtl,
      this.permissions = const [],
      this.writableDirs = const [],
      this.memoryOff,
      this.headless});

  String? model;
  String? provider;
  ApproveMode? approveMode;

  /// This chat's own standing rules, in front of the project's and the app's.
  /// What "Allow in Chat" on a banner writes.
  List<PermissionRule> permissions;

  /// Machine directories this chat's sandboxed commands may write to, beside
  /// the workspace — what "Allow in Chat" on a sandbox-denied write grants.
  /// In front of the project's list.
  List<String> writableDirs;

  /// How long this chat lives once its TTL is enabled. Null means inherit the
  /// project (if set) or app default.
  TempChatTtl? tempChatTtl;

  /// Whether this chat keeps out of the auto-memory: the recall, the
  /// extraction and the memory tools. The instruction files keep reaching it —
  /// they are read into every turn. Null means follow whatever the project
  /// answers, and a project that takes the subsystem away cannot be given it
  /// back from here.
  bool? memoryOff;

  /// A chat nobody watches — a reminder's. Every turn on it drops `ask_user`
  /// and `task`, since nobody is there to answer or to need the fan-out, and
  /// suppresses the title model, since the reminder already named the chat. Null
  /// means an ordinary chat the user drives.
  bool? headless;

  factory ChatMeta.fromJson(Map<String, dynamic> json) => ChatMeta(
        model: json["model"] as String?,
        provider: json["provider"] as String?,
        approveMode: _approveMode(json),
        permissions: permissionRulesFromJson(json["permissions"] as List<dynamic>?),
        writableDirs: [
          for (final w in (json["writableDirs"] as List<dynamic>? ?? const []))
            if (w is String) w,
        ],
        tempChatTtl: TempChatTtl.fromNameNullable(json["tempChatTtl"] as String?),
        memoryOff: json["memoryOff"] as bool?,
        headless: json["headless"] as bool?,
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
        permissions: permissions,
        writableDirs: writableDirs,
        tempChatTtl: tempChatTtl,
        memoryOff: memoryOff,
        headless: headless,
      );

  /// Nothing overridden, so nothing to write down: this chat inherits the
  /// project's answers and the app's, which is what no `meta.json` means.
  bool get isEmpty => toJson().isEmpty;

  Map<String, dynamic> toJson() => {
        if (model != null) "model": model,
        if (provider != null) "provider": provider,
        if (approveMode != null) "approveMode": approveMode!.name,
        if (permissions.isNotEmpty)
          "permissions": permissionRulesToJson(permissions),
        if (writableDirs.isNotEmpty) "writableDirs": writableDirs,
        if (tempChatTtl != null) "tempChatTtl": tempChatTtl!.name,
        if (memoryOff != null) "memoryOff": memoryOff,
        if (headless != null) "headless": headless,
      };

  String encode() => jsonEncode(toJson());
}
