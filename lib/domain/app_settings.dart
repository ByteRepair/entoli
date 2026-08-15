import "dart:convert";

import "../core/config.dart";
import "app_icon.dart";
import "llm_provider.dart";
import "permission.dart";
import "profile.dart";

/// Persisted app-level settings (default model for new chats, etc.).
class AppSettings {
  AppSettings({
    this.defaultModelId,
    this.defaultProviderId,
    this.titleModelId,
    this.titleProviderId,
    this.classifierModelId,
    this.classifierProviderId,
    this.environment = const {},
    this.approveMode = ApproveMode.ask,
    this.llmProviders = const [],
    this.profile,
    this.appIcon = AppIcon.prompt,
  });

  String? defaultModelId;
  String? defaultProviderId;

  /// What names a chat after its first message. Both halves or neither: with
  /// nothing here the feature is off and a chat keeps the name it was made
  /// with.
  String? titleModelId;
  String? titleProviderId;

  /// What classifies a command as safe enough to run without asking, when
  /// [approveMode] is [ApproveMode.auto]. Both halves or neither: with nothing
  /// here auto mode falls back to asking for every command.
  String? classifierModelId;
  String? classifierProviderId;

  /// Environment variables the agent's commands run under, and that a provider
  /// may name instead of holding its key. Held here rather than in the shell
  /// because the settings page edits them.
  Map<String, String> environment;

  /// How the agent handles a command before it runs. A chat can override it.
  ApproveMode approveMode;

  /// The endpoints the agent can call. Empty until the user adds one, which is
  /// why the first thing settings offers is a list of presets.
  List<LlmProviderConfig> llmProviders;

  /// The user's profile, injected at the end of the system prompt. App-level
  /// default; a project can override it. Null means nothing is injected.
  Profile? profile;

  /// Which icon the app wears, in the app and on the Android home screen.
  /// App-level only: an icon is the app's, not a chat's.
  AppIcon appIcon;

  static AppSettings load(AppConfig config) {
    final text = AppConfig.readText(config.settingsFile);
    if (text == null) return AppSettings();
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      return AppSettings(
        defaultModelId: _orNull(json["defaultModelId"] as String?),
        defaultProviderId: _orNull(json["defaultProviderId"] as String?),
        titleModelId: _orNull(json["titleModelId"] as String?),
        titleProviderId: _orNull(json["titleProviderId"] as String?),
        classifierModelId: _orNull(json["classifierModelId"] as String?),
        classifierProviderId: _orNull(json["classifierProviderId"] as String?),
        // `opencodeEnv` is what this was called when a second backend spawned
        // servers. Read-only: `save` writes `environment`, so a file migrates
        // itself the first time anything is changed, and the fallback can go
        // once no unwritten files are left.
        environment: _stringMap(json["environment"] ?? json["opencodeEnv"]),
        approveMode: _approveMode(json),
        llmProviders: _providers(json["llmProviders"]),
        profile: Profile.fromJson(json["profile"]),
        appIcon: AppIcon.fromName(json["appIcon"] as String?),
      );
    } catch (_) {
      return AppSettings();
    }
  }

  /// `approveMode` is the current key. An older file has `approveCommands` as
  /// a bool, migrated by [approveModeFromJson]. A file with neither is the
  /// default, [ApproveMode.ask].
  static ApproveMode _approveMode(Map<String, dynamic> json) =>
      approveModeFromJson(json) ?? ApproveMode.ask;

  // Builds before the /provider flattening fix wrote empty ids here.
  static String? _orNull(String? v) => (v == null || v.isEmpty) ? null : v;

  static List<LlmProviderConfig> _providers(Object? value) {
    if (value is! List) return const [];
    return [
      for (final entry in value) ?LlmProviderConfig.fromJson(entry),
    ];
  }

  static Map<String, String> _stringMap(Object? value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        if (entry.value is String) entry.key.toString(): entry.value as String,
    };
  }

  /// A fresh instance holding the same values, for a notifier that has to hand
  /// out a new object to be noticed. The fields are mutable, so a caller
  /// changes what it means to with a cascade — which keeps `null` meaning
  /// "not set" rather than "leave alone", and needs no sentinel to say so.
  AppSettings copy() => AppSettings(
        defaultModelId: defaultModelId,
        defaultProviderId: defaultProviderId,
        titleModelId: titleModelId,
        titleProviderId: titleProviderId,
        classifierModelId: classifierModelId,
        classifierProviderId: classifierProviderId,
        environment: environment,
        approveMode: approveMode,
        llmProviders: llmProviders,
        profile: profile,
        appIcon: appIcon,
      );

  Future<void> save(AppConfig config) async {
    AppConfig.writeText(config.settingsFile, jsonEncode({
      if (defaultModelId != null) "defaultModelId": defaultModelId,
      if (defaultProviderId != null) "defaultProviderId": defaultProviderId,
      if (titleModelId != null) "titleModelId": titleModelId,
      if (titleProviderId != null) "titleProviderId": titleProviderId,
      if (classifierModelId != null) "classifierModelId": classifierModelId,
      if (classifierProviderId != null) "classifierProviderId": classifierProviderId,
      if (environment.isNotEmpty) "environment": environment,
      "approveMode": approveMode.name,
      if (llmProviders.isNotEmpty)
        "llmProviders": [for (final provider in llmProviders) provider.toJson()],
      if (profile != null && !profile!.isEmpty) "profile": profile!.toJson(),
      "appIcon": appIcon.name,
    }));
  }
}
