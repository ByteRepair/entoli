import "dart:convert";

import "model_options.dart";
import "permission.dart";
import "settings/keys.dart";
import "settings/setting.dart";
import "temp_chat_ttl.dart";

/// A chat's overrides of the app defaults, persisted to `meta.json`: a typed
/// view of its document, where unset inherits the project's and the app's.
/// Distinct from `state.json` (chat metadata) and `conv.jsonl` (message tree).
class ChatMeta {
  ChatMeta({
    String? model,
    String? provider,
    ApproveMode? approveMode,
    ReasoningEffort? reasoningEffort,
    TempChatTtl? tempChatTtl,
    List<PermissionRule> permissions = const [],
    List<String> writableDirs = const [],
    bool? memoryOff,
    bool? sandbox,
    bool? headless,
  }) : doc = SettingsDocument() {
    this
      ..model = model
      ..provider = provider
      ..approveMode = approveMode
      ..reasoningEffort = reasoningEffort
      ..tempChatTtl = tempChatTtl
      ..permissions = permissions
      ..writableDirs = writableDirs
      ..memoryOff = memoryOff
      ..sandbox = sandbox
      ..headless = headless;
  }

  ChatMeta.of(this.doc);

  final SettingsDocument doc;

  String? get model => doc.read(SettingKeys.model);
  set model(String? value) => doc.set(SettingKeys.model, value);

  String? get provider => doc.read(SettingKeys.provider);
  set provider(String? value) => doc.set(SettingKeys.provider, value);

  ApproveMode? get approveMode => doc.read(SettingKeys.approveMode);
  set approveMode(ApproveMode? value) =>
      doc.set(SettingKeys.approveMode, value);

  ReasoningEffort? get reasoningEffort => doc.read(SettingKeys.reasoningEffort);
  set reasoningEffort(ReasoningEffort? value) =>
      doc.set(SettingKeys.reasoningEffort, value);

  TempChatTtl? get tempChatTtl => doc.read(SettingKeys.tempChatTtl);
  set tempChatTtl(TempChatTtl? value) =>
      doc.set(SettingKeys.tempChatTtl, value);

  /// In front of the project's and the app's. What "Allow in Chat" on a
  /// banner writes.
  List<PermissionRule> get permissions =>
      doc.read(SettingKeys.permissions) ?? const [];
  set permissions(List<PermissionRule> value) =>
      doc.set(SettingKeys.permissions, value);

  /// What "Allow in Chat" on a sandbox-denied write grants. In front of the
  /// project's list.
  List<String> get writableDirs =>
      doc.read(SettingKeys.writableDirs) ?? const [];
  set writableDirs(List<String> value) =>
      doc.set(SettingKeys.writableDirs, value);

  bool? get memoryOff => doc.read(SettingKeys.memoryOff);
  set memoryOff(bool? value) => doc.set(SettingKeys.memoryOff, value);

  bool? get sandbox => doc.read(SettingKeys.sandbox);
  set sandbox(bool? value) => doc.set(SettingKeys.sandbox, value);

  bool? get headless => doc.read(SettingKeys.headless);
  set headless(bool? value) => doc.set(SettingKeys.headless, value);

  factory ChatMeta.fromJson(Map<String, dynamic> json) =>
      ChatMeta.of(SettingsDocument(json: json));

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

  /// The same overrides again, to be edited without the original moving. The
  /// values are mutable and the settings page writes them in place, so a page
  /// backed out of has to leave what it was handed alone.
  ChatMeta copy() => ChatMeta.of(doc.copy());

  /// Nothing overridden, so nothing to write down: this chat inherits the
  /// project's answers and the app's, which is what no `meta.json` means.
  bool get isEmpty => doc.isEmpty;

  Map<String, dynamic> toJson() => doc.toJson();

  String encode() => jsonEncode(toJson());
}
