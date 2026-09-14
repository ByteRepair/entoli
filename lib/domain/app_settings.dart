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
import "project_settings.dart";
import "temp_chat_ttl.dart";
import "theme_colour.dart";
import "tone.dart";

/// Persisted app-level settings (default model for new chats, etc.).
class AppSettings {
  AppSettings({
    this.defaultModelId,
    this.defaultProviderId,
    this.titleModelId,
    this.titleProviderId,
    this.classifierModelId,
    this.classifierProviderId,
    this.instructionImports = true,
    this.nestedInstructions = true,
    this.instructionExcludes = const [],
    this.autoMemory = false,
    this.memoryRecall = true,
    this.memoryExtraction = true,
    this.memoryAgentTool = true,
    this.memoryModelId,
    this.memoryProviderId,
    this.environment = const {},
    this.approveMode = ApproveMode.ask,
    this.llmProviders = const [],
    this.profile,
    this.tone = Tone.none,
    this.citations = false,
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
    this.deviceName,
    this.syncRelayUrl,
    this.syncKeepAlive = false,
    this.turnUrl,
    this.turnUsername,
    this.turnRetries = defaultTurnRetries,
    this.omadaByDefault = false,
    this.omadaMaxGenerations = defaultOmadaMaxGenerations,
    this.omadaOrdering,
    this.turnMaxSteps,
    this.welcomeSeen = false,
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

  /// Whether `@path` references inside an AGENTS.md pull in more files. The
  /// files themselves are read into every turn; this and [nestedInstructions]
  /// only reach further than the two of them.
  bool instructionImports;

  /// Whether reading a file in a subdirectory that has its own AGENTS.md
  /// pulls that file into the turn.
  bool nestedInstructions;

  /// Glob patterns that keep an AGENTS.md out of a turn: a file whose path
  /// one of them names is skipped, wherever the load meets it; empty skips
  /// nothing.
  List<String> instructionExcludes;

  /// Whether the auto-memory subsystem runs: a per-project store of markdown
  /// memories the agent reads, recalls and writes with a background model.
  /// Off by default, and inert beside it until [memoryModelId] is set.
  bool autoMemory;

  /// What writes memories in the background (extraction after a turn,
  /// consolidation between chats). Both halves or neither: with nothing here
  /// auto-memory stays read-only — nothing is written on the user's behalf
  /// by a model they have not chosen.
  String? memoryModelId;
  String? memoryProviderId;

  /// Whether relevant memories are recalled into each turn. A sub-gate of
  /// [autoMemory], on by default: the store is read-only from the turn's point
  /// of view, so the cost is prompt size, capped.
  bool memoryRecall;

  /// Whether a background model writes memories from a turn after it ends.
  /// A sub-gate of [autoMemory], on by default, inert beside it until
  /// [memoryModelId] is set.
  bool memoryExtraction;

  /// Whether the agent is offered the `memorySave` and `memorySearch` tools.
  /// A sub-gate of [autoMemory], on by default: a memory it decides to keep is
  /// one it judged worth keeping, rather than one a background pass guessed at.
  bool memoryAgentTool;

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

  /// How the agent words its replies. App-level default; a project can
  /// override it. [Tone.none] adds nothing to the prompt.
  Tone tone;

  /// Whether the agent numbers the web pages a reply drew on and lists them
  /// at the end of it. It names what it used, never a search it was not
  /// asked to make. App-level default; a project can override it.
  bool citations;

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

  /// This device's name as paired devices see it. Null falls back to
  /// "Entoli " plus a fingerprint prefix in [SyncHub].
  String? deviceName;

  /// A user-supplied WebSocket relay endpoint for pairing over the internet.
  /// Empty or null means relay is off and only LAN / manual paste work.
  String? syncRelayUrl;

  /// Whether a connected peer holds the process open off screen, as a
  /// foreground service with a notification naming the connected devices and
  /// a Disconnect action. Off by default: the cost is a wake lock and a
  /// persistent notification for as long as a device is connected. Android
  /// only; a no-op everywhere a foreground service cannot be started.
  bool syncKeepAlive;

  /// TURN server URL for NAT traversal. Bring-your-own; STUN defaults are
  /// public. Null means no TURN, so symmetric-NAT pairs fail honestly.
  String? turnUrl;

  /// TURN credentials, stored beside the URL. Null where the TURN server
  /// needs none (rare) or none is configured. The password is not here: it is
  /// a secret, and lives in the [AppSecrets] store beside the sync identity.
  String? turnUsername;

  /// How many times a turn that died on a retryable error — a connection that
  /// dropped, a provider hiccup — is carried on automatically before it is
  /// left failed. `0` is off: the turn stops where it failed and the Continue
  /// bar is the only way on. App-level, like the model default it sits beside.
  int turnRetries;

  /// Whether a new project starts with Omada on, so the user who wants a
  /// workspace of teams does not flip the toggle per project. Baked into the
  /// project at creation; existing projects and the built-ins are untouched.
  bool omadaByDefault;

  /// How many handoff generations one Omada round may run — dispatch waves,
  /// not turns: a three-member fan-out is one generation. The user's message
  /// is generation one and uncapped; this bounds the waves that follow, and
  /// the user speaking resets the count. A project's
  /// `ProjectSettings.omadaMaxGenerations` overrides it per project.
  int omadaMaxGenerations;

  /// The room's scheduling default for a project that picked none of its own:
  /// sequential runs the schedule one turn at a time, parallel answers with
  /// one turn per member at once. `ProjectSettings.omadaOrdering` overrides
  /// it per project; the enum lives with the project settings, which is
  /// where a per-project answer was first written.
  OmadaOrdering? omadaOrdering;

  /// How many model calls one turn may make before it stops for the user —
  /// the step limit the backend runs under. Null is the backend's own
  /// default; the value rides every turn, an Omada member turn included,
  /// and the round's own bound is `omadaMaxGenerations` beside it.
  int? turnMaxSteps;

  /// Whether the welcome tour has been finished. It is what first launch reads
  /// to decide whether to push the tour, and what its Done writes.
  bool welcomeSeen;

  /// The default when nothing is set: five carry-ons per failure. A named
  /// constant so the settings page's switch — which turns the feature on at
  /// the default — and the load and save answers are one number.
  static const defaultTurnRetries = 5;

  /// The most the setting may say, and the slider's top.
  static const maxTurnRetries = 10;

  /// The default and the stops of the max-generations slider. Ten waves of
  /// agent-to-agent work before the round stops for the user.
  static const defaultOmadaMaxGenerations = 10;
  static const omadaGenerationStops = [5, 10, 20, 40, 60, 80, 100];

  /// The stops of the max-steps dropdown, and the backend default the
  /// "Default" entry names.
  static const turnStepStops = [20, 40, 60, 80, 100, 150];
  static const defaultTurnMaxSteps = 40;

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
        instructionImports: json["instructionImports"] as bool? ?? true,
        nestedInstructions: json["nestedInstructions"] as bool? ?? true,
        instructionExcludes:
            (json["instructionExcludes"] as List? ?? const [])
                .map((e) => e as String)
                .toList(),
        autoMemory: json["autoMemory"] as bool? ?? false,
        // Written only when off, so a file that predates them says nothing and
        // gets the on defaults.
        memoryRecall: json["memoryRecall"] as bool? ?? true,
        memoryExtraction: json["memoryExtraction"] as bool? ?? true,
        memoryAgentTool: json["memoryAgentTool"] as bool? ?? true,
        memoryModelId: _orNull(json["memoryModelId"] as String?),
        memoryProviderId: _orNull(json["memoryProviderId"] as String?),
        // `opencodeEnv` is what this was called when a second backend spawned
        // servers. Read-only: `save` writes `environment`, so a file migrates
        // itself the first time anything is changed, and the fallback can go
        // once no unwritten files are left.
        environment: _stringMap(json["environment"] ?? json["opencodeEnv"]),
        approveMode: _approveMode(json),
        llmProviders: _providers(json["llmProviders"]),
        profile: Profile.fromJson(json["profile"]),
        tone: Tone.fromJson(json["tone"]),
        citations: json["citations"] as bool? ?? false,
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
        deviceName: _orNull(json["deviceName"] as String?),
        syncRelayUrl: _orNull(json["syncRelayUrl"] as String?),
        syncKeepAlive: json["syncKeepAlive"] as bool? ?? false,
        turnUrl: _orNull(json["turnUrl"] as String?),
        turnUsername: _orNull(json["turnUsername"] as String?),
        turnRetries:
            (json["turnRetries"] as int? ?? defaultTurnRetries).clamp(0, maxTurnRetries),
        omadaByDefault: json["omadaByDefault"] as bool? ?? false,
        omadaMaxGenerations:
            (json["omadaMaxGenerations"] as int? ?? defaultOmadaMaxGenerations),
        omadaOrdering: OmadaOrdering.fromNameNullable(
            json["omadaOrdering"] as String?),
        turnMaxSteps: json["turnMaxSteps"] as int?,
        welcomeSeen: json["welcomeSeen"] as bool? ?? false,
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

        instructionImports: instructionImports,
        nestedInstructions: nestedInstructions,
        instructionExcludes: instructionExcludes,
        autoMemory: autoMemory,
        memoryRecall: memoryRecall,
        memoryExtraction: memoryExtraction,
        memoryAgentTool: memoryAgentTool,
        memoryModelId: memoryModelId,
        memoryProviderId: memoryProviderId,
        environment: environment,
        approveMode: approveMode,
        llmProviders: llmProviders,
        profile: profile,
        tone: tone,
        citations: citations,
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
        deviceName: deviceName,
        syncRelayUrl: syncRelayUrl,
        syncKeepAlive: syncKeepAlive,
        turnUrl: turnUrl,
        turnUsername: turnUsername,
        turnRetries: turnRetries,
        omadaByDefault: omadaByDefault,
        omadaMaxGenerations: omadaMaxGenerations,
        omadaOrdering: omadaOrdering,
        turnMaxSteps: turnMaxSteps,
        welcomeSeen: welcomeSeen,
      );

  Future<void> save(AppConfig config) async {
    await config.documents.write(config.settingsFile, jsonEncode({
      if (defaultModelId != null) "defaultModelId": defaultModelId,
      if (defaultProviderId != null) "defaultProviderId": defaultProviderId,
      if (titleModelId != null) "titleModelId": titleModelId,
      if (titleProviderId != null) "titleProviderId": titleProviderId,
      if (classifierModelId != null) "classifierModelId": classifierModelId,
      if (classifierProviderId != null) "classifierProviderId": classifierProviderId,
      // Written only when off, so a file that predates the on defaults says
      // nothing and gets them.
      if (!instructionImports) "instructionImports": instructionImports,
      if (!nestedInstructions) "nestedInstructions": nestedInstructions,
      if (instructionExcludes.isNotEmpty)
        "instructionExcludes": instructionExcludes,
      if (autoMemory) "autoMemory": autoMemory,
      if (!memoryRecall) "memoryRecall": memoryRecall,
      if (!memoryExtraction) "memoryExtraction": memoryExtraction,
      if (!memoryAgentTool) "memoryAgentTool": memoryAgentTool,
      if (memoryModelId != null) "memoryModelId": memoryModelId,
      if (memoryProviderId != null) "memoryProviderId": memoryProviderId,
      if (environment.isNotEmpty) "environment": environment,
      "approveMode": approveMode.name,
      if (llmProviders.isNotEmpty)
        "llmProviders": [for (final provider in llmProviders) provider.toJson()],
      if (profile != null && !profile!.isEmpty) "profile": profile!.toJson(),
      if (tone != Tone.none) "tone": tone.name,
      if (citations) "citations": citations,
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
      if (deviceName != null) "deviceName": deviceName,
      if (syncRelayUrl != null) "syncRelayUrl": syncRelayUrl,
      if (syncKeepAlive) "syncKeepAlive": syncKeepAlive,
      if (turnUrl != null) "turnUrl": turnUrl,
      if (turnUsername != null) "turnUsername": turnUsername,
      // Written only when not the default, for the same reason the memory
      // gates are: a file that predates it says nothing and gets the default.
      if (turnRetries != defaultTurnRetries) "turnRetries": turnRetries,
      if (omadaByDefault) "omadaByDefault": omadaByDefault,
      if (omadaMaxGenerations != defaultOmadaMaxGenerations)
        "omadaMaxGenerations": omadaMaxGenerations,
      if (omadaOrdering != null) "omadaOrdering": omadaOrdering!.name,
      if (turnMaxSteps != null) "turnMaxSteps": turnMaxSteps,
      if (welcomeSeen) "welcomeSeen": welcomeSeen,
    }));
  }
}
