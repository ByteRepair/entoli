import "dart:convert";

import "../core/config.dart";
import "app_icon.dart";
import "app_theme.dart";
import "assistant_view.dart";
import "llm_provider.dart";
import "permission.dart";
import "profile.dart";
import "temp_chat_ttl.dart";

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
    this.appIcon = AppIcon.cookie,
    this.appTheme = AppTheme.system,
    this.tempChatTtl = TempChatTtl.off,
    this.voiceRecognitionModelId,
    this.voiceSpeechModelId,
    this.voiceSpeaker = 0,
    this.assistantProject,
    this.assistantView = AssistantView.chat,
    this.rootfsId,
    this.localModelId,
    this.localModelDevice,
    this.localModelContext,
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

  /// Which palette the app draws. App-level only, for the same reason.
  AppTheme appTheme;

  /// How long a temporary chat lives once its TTL is enabled. App-level
  /// default; a project and a chat can override it. [TempChatTtl.off] means
  /// temporary chats are off — chats live forever.
  TempChatTtl tempChatTtl;

  /// Which voice models listen and speak, by catalog id, and which of a
  /// multi-voice model's speakers is used. App-level only, like the icon and
  /// the theme: a voice is the app's, not a conversation's. Either being null
  /// is voice mode not set up yet, which is what takes the button off the
  /// composer.
  String? voiceRecognitionModelId;
  String? voiceSpeechModelId;
  int voiceSpeaker;

  /// Which project the system's assistant gesture opens a chat in. Null is the
  /// default project, the same null `selectedProjectProvider` uses. App-level:
  /// the assistant is the app's, not a conversation's. See issue #54.
  String? assistantProject;

  /// Which view the assistant gesture opens. App-level, for the same reason.
  AssistantView assistantView;

  /// The Linux the agent's commands run inside, by catalog id. Null is Android
  /// itself, which is where every command ran before there was anything else to
  /// run one in — and so what an existing `settings.json` already says by
  /// saying nothing. App-level: which machine the agent is on is the app's, and
  /// a chat moved between the two mid-conversation would be a conversation
  /// about a filesystem that is no longer there.
  String? rootfsId;

  /// The model served from this device, by catalog id, or null for none — which
  /// is what every existing `settings.json` already says by saying nothing.
  /// Picking one starts the server at the next launch as well as at this one,
  /// so it is the pick that is stored rather than whether it happens to be up.
  ///
  /// App-level, like the icon and the voice: which model a chat uses is already
  /// a per-chat setting, and this is the machine underneath it.
  String? localModelId;

  /// The accelerator it is offloaded to, by the name `--list-devices` gave it.
  /// Null is the CPU, which is every device's answer and most devices' only
  /// one. Stored as the name rather than as a kind, because that is the string
  /// the server is passed and a phone can have two of the same kind.
  String? localModelDevice;

  /// How much context it is loaded with, or null for the default. The one
  /// setting here that is really about memory: it is the KV cache that decides
  /// whether Android kills the app, not the weights, which are mapped.
  int? localModelContext;

  static AppSettings load(AppConfig config) {
    final text = config.documents.read(config.settingsFile);
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
        appTheme: AppTheme.fromName(json["appTheme"] as String?),
        tempChatTtl: TempChatTtl.fromName(json["tempChatTtl"] as String?),
        voiceRecognitionModelId: _orNull(json["voiceRecognitionModelId"] as String?),
        voiceSpeechModelId: _orNull(json["voiceSpeechModelId"] as String?),
        voiceSpeaker: json["voiceSpeaker"] as int? ?? 0,
        assistantProject: _orNull(json["assistantProject"] as String?),
        assistantView: AssistantView.fromName(json["assistantView"] as String?),
        rootfsId: _orNull(json["rootfsId"] as String?),
        localModelId: _orNull(json["localModelId"] as String?),
        localModelDevice: _orNull(json["localModelDevice"] as String?),
        localModelContext: json["localModelContext"] as int?,
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
        appTheme: appTheme,
        tempChatTtl: tempChatTtl,
        voiceRecognitionModelId: voiceRecognitionModelId,
        voiceSpeechModelId: voiceSpeechModelId,
        voiceSpeaker: voiceSpeaker,
        assistantProject: assistantProject,
        assistantView: assistantView,
        rootfsId: rootfsId,
        localModelId: localModelId,
        localModelDevice: localModelDevice,
        localModelContext: localModelContext,
      );

  Future<void> save(AppConfig config) async {
    await config.documents.write(config.settingsFile, jsonEncode({
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
      "appTheme": appTheme.name,
      "tempChatTtl": tempChatTtl.name,
      if (voiceRecognitionModelId != null)
        "voiceRecognitionModelId": voiceRecognitionModelId,
      if (voiceSpeechModelId != null) "voiceSpeechModelId": voiceSpeechModelId,
      if (voiceSpeaker != 0) "voiceSpeaker": voiceSpeaker,
      if (assistantProject != null) "assistantProject": assistantProject,
      "assistantView": assistantView.name,
      if (rootfsId != null) "rootfsId": rootfsId,
      if (localModelId != null) "localModelId": localModelId,
      if (localModelDevice != null) "localModelDevice": localModelDevice,
      if (localModelContext != null) "localModelContext": localModelContext,
    }));
  }
}
