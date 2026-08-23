import "dart:convert";

import "../core/config.dart";
import "app_icon.dart";
import "app_theme.dart";
import "assistant_view.dart";
import "corner_radius.dart";
import "llm_provider.dart";
import "local_llm.dart";
import "permission.dart";
import "profile.dart";
import "temp_chat_ttl.dart";
import "theme_colour.dart";

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
    this.primaryColour = ThemeColour.indigo,
    this.secondaryColour = ThemeColour.indigo,
    this.cornerRadius = CornerRadius.medium,
    this.systemPalette = false,
    this.tempChatTtl = TempChatTtl.off,
    this.voiceRecognitionModelId,
    this.voiceSpeechModelId,
    this.voiceSpeaker = 0,
    this.voiceLanguage,
    this.voicePushToTalk = false,
    this.assistantProject,
    this.assistantView = AssistantView.chat,
    this.rootfsId,
    this.maxLocalModels = 1,
    this.localModelDevice,
    this.localModelContext,
    this.localModelPrefill = false,
    this.localModelThreads,
    this.localModelKvCachePrompts,
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

  /// The two colours the palette is built from: the primary is the seed, and
  /// the secondary seeds the accent group beside it. Both indigo is the app's
  /// own scheme, where the secondary is whatever Material derives from the one
  /// seed. App-level, like the theme and the icon.
  ThemeColour primaryColour;
  ThemeColour secondaryColour;

  /// How round the corners the theme rounds are — fields, dialogs, menus,
  /// sheets and buttons.
  CornerRadius cornerRadius;

  /// Whether the palette comes from the system instead of the two colours
  /// above — Android's Material 3 Expressive, which follows the wallpaper.
  /// Ignored where the platform has no accent to give.
  bool systemPalette;

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

  /// Which language the device's own engines are asked to hear and speak in,
  /// as a BCP-47 tag. Null is the device's own — see `Voice.systemLanguages`.
  String? voiceLanguage;

  /// Whether the microphone is open only while a button is held. Off is voice
  /// mode listening for as long as it is on screen, which is what it is for;
  /// on is for a room where that does not work — a recogniser transcribes
  /// whatever is loud enough, and somewhere noisy enough the only reliable
  /// answer is for the user to say when.
  bool voicePushToTalk;

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

  /// How many on-device models may be loaded at once, capped at
  /// [maxLocalModelsAllowed]. One is the default because each is a process
  /// holding a set of weights and a gigabyte of KV cache; two is what makes a
  /// small model naming chats beside a large one answering them worth setting,
  /// and is what stops the two evicting each other turn after turn.
  int maxLocalModels;

  /// The accelerator it is offloaded to, by the name `--list-devices` gave it.
  /// Null is auto — the best one the phone turned out to have — and
  /// `LocalDevice.cpu` is how the picker rules them all out. Stored as the name
  /// rather than as a kind, because that is the string the server is passed and
  /// a phone can have two of the same kind.
  String? localModelDevice;

  /// How much context every on-device model is loaded with, or null to let each
  /// one answer for itself — `LocalModel.defaultContext`, which is what its own
  /// KV cache costs divided into [kvBudgetBytes]. Set here, it overrides that
  /// for all of them, which is the honest shape now that any downloaded model
  /// can be the one a turn asks for.
  int? localModelContext;

  /// Whether to warm an on-device model's system-prompt KV in the background
  /// when it is set as a default, so the first chat does not pay the whole
  /// prompt at once. Off by default: it is minutes of the CPU on a phone, so it
  /// is the user's to ask for. See "Prefilling the system prompt" in
  /// `lib/data/local/CLAUDE.md`.
  bool localModelPrefill;

  /// How many CPU cores the model server may run on, or null for the default —
  /// every big core (`bigCoreCount`). Lowering it trades tokens-per-second for
  /// battery, which is the only reason to. Read per launch, so a change reaches
  /// the next server rather than the running one.
  int? localModelThreads;

  /// How many prompt prefixes the on-device provider keeps warmed on disk, so
  /// reopening a chat restores its KV rather than reprocessing it. Null is the
  /// default (10) and `0` is off — nothing is written.
  ///
  /// One prompt is one request to the model, so it is neither per chat nor per
  /// turn: a turn writes one for each step it takes, and the bound is over
  /// every chat at once. It was called `Chats` and counted neither. See
  /// "Persisting the KV cache to disk" in `lib/data/local/CLAUDE.md`.
  int? localModelKvCachePrompts;

  /// The default when nothing is set: on, at ten prefixes. A named constant so
  /// the UI's "Default (10)" label and the provider's effective count are one
  /// number.
  static const defaultKvCachePrompts = 10;

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
        primaryColour: ThemeColour.fromName(json["primaryColour"] as String?),
        secondaryColour: ThemeColour.fromName(json["secondaryColour"] as String?),
        cornerRadius: CornerRadius.fromName(json["cornerRadius"] as String?),
        systemPalette: json["systemPalette"] as bool? ?? false,
        tempChatTtl: TempChatTtl.fromName(json["tempChatTtl"] as String?),
        voiceRecognitionModelId: _orNull(json["voiceRecognitionModelId"] as String?),
        voiceSpeechModelId: _orNull(json["voiceSpeechModelId"] as String?),
        voiceSpeaker: json["voiceSpeaker"] as int? ?? 0,
        voiceLanguage: _orNull(json["voiceLanguage"] as String?),
        voicePushToTalk: json["voicePushToTalk"] as bool? ?? false,
        assistantProject: _orNull(json["assistantProject"] as String?),
        assistantView: AssistantView.fromName(json["assistantView"] as String?),
        rootfsId: _orNull(json["rootfsId"] as String?),
        maxLocalModels:
            (json["maxLocalModels"] as int? ?? 1).clamp(1, maxLocalModelsAllowed),
        localModelDevice: _orNull(json["localModelDevice"] as String?),
        localModelContext: json["localModelContext"] as int?,
        localModelPrefill: json["localModelPrefill"] as bool? ?? false,
        localModelThreads: json["localModelThreads"] as int?,
        // `localModelKvCacheChats` is what this was called while it was thought
        // to count chats. Read-only, like `opencodeEnv` above: `save` writes
        // the new name, so a file migrates itself on the next change.
        localModelKvCachePrompts: (json["localModelKvCachePrompts"] ??
            json["localModelKvCacheChats"]) as int?,
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
        primaryColour: primaryColour,
        secondaryColour: secondaryColour,
        cornerRadius: cornerRadius,
        systemPalette: systemPalette,
        tempChatTtl: tempChatTtl,
        voiceRecognitionModelId: voiceRecognitionModelId,
        voiceSpeechModelId: voiceSpeechModelId,
        voiceSpeaker: voiceSpeaker,
        voiceLanguage: voiceLanguage,
        voicePushToTalk: voicePushToTalk,
        assistantProject: assistantProject,
        assistantView: assistantView,
        rootfsId: rootfsId,
        maxLocalModels: maxLocalModels,
        localModelDevice: localModelDevice,
        localModelContext: localModelContext,
        localModelPrefill: localModelPrefill,
        localModelThreads: localModelThreads,
        localModelKvCachePrompts: localModelKvCachePrompts,
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
      "primaryColour": primaryColour.name,
      "secondaryColour": secondaryColour.name,
      "cornerRadius": cornerRadius.name,
      "systemPalette": systemPalette,
      "tempChatTtl": tempChatTtl.name,
      if (voiceRecognitionModelId != null)
        "voiceRecognitionModelId": voiceRecognitionModelId,
      if (voiceSpeechModelId != null) "voiceSpeechModelId": voiceSpeechModelId,
      if (voiceSpeaker != 0) "voiceSpeaker": voiceSpeaker,
      if (voiceLanguage != null) "voiceLanguage": voiceLanguage,
      if (voicePushToTalk) "voicePushToTalk": voicePushToTalk,
      if (assistantProject != null) "assistantProject": assistantProject,
      "assistantView": assistantView.name,
      if (rootfsId != null) "rootfsId": rootfsId,
      if (maxLocalModels != 1) "maxLocalModels": maxLocalModels,
      if (localModelDevice != null) "localModelDevice": localModelDevice,
      if (localModelContext != null) "localModelContext": localModelContext,
      if (localModelPrefill) "localModelPrefill": localModelPrefill,
      if (localModelThreads != null) "localModelThreads": localModelThreads,
      if (localModelKvCachePrompts != null)
        "localModelKvCachePrompts": localModelKvCachePrompts,
    }));
  }
}
