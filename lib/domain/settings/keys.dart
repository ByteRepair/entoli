import "../agent_browser.dart" show BrowserApproval, BrowserUploadPolicy;
import "../app_theme.dart";
import "../assistant_view.dart";
import "../corner_radius.dart";
import "../llm_provider.dart";
import "../local_llm.dart" show maxLocalModelsAllowed;
import "../local_model.dart" show localProviderId;
import "../model_capability.dart" show ModelRef;
import "../model_options.dart";
import "../omada_ordering.dart";
import "../permission.dart";
import "../profile.dart";
import "../temp_chat_ttl.dart";
import "../theme_colour.dart";
import "../tone.dart";
import "../tristate.dart";
import "setting.dart";

// `opencodeEnv` is what the environment was called when a second backend
// spawned servers.
Map<String, String>? _opencodeEnv(Map<String, Object?> json) =>
    const StringMapCodec().decode(json["opencodeEnv"]);

// `localModelKvCacheChats` is what this was called while it was thought to
// count chats.
int? _kvCacheChats(Map<String, Object?> json) =>
    const IntCodec().decode(json["localModelKvCacheChats"]);

// `useProjectMemory` is the bool the tristate replaced; true was a store of
// the project's own.
Tristate? _useProjectMemory(Map<String, Object?> json) =>
    json["useProjectMemory"] == true ? Tristate.on : null;

// A name this build does not know asks, the cautious answer.
ApproveMode? _decodeApproveMode(Object? raw) => raw is String
    ? ApproveMode.values.asNameMap()[raw] ?? ApproveMode.ask
    : null;
Object _encodeEnum(Enum value) => value.name;

List<LlmProviderConfig>? _decodeProviders(Object? raw) => raw is List
    ? [for (final entry in raw) ?LlmProviderConfig.fromJson(entry)]
    : null;
Object _encodeProviders(List<LlmProviderConfig> value) => [
  for (final provider in value) provider.toJson(),
];
bool _noProviders(List<LlmProviderConfig> value) => value.isEmpty;

Profile? _decodeProfile(Object? raw) {
  final profile = Profile.fromJson(raw);
  return profile == null || profile.isEmpty ? null : profile;
}

Object _encodeProfile(Profile value) => value.toJson();
bool _emptyProfile(Profile value) => value.isEmpty;

List<PermissionRule>? _decodeRules(Object? raw) =>
    raw is List ? permissionRulesFromJson(raw) : null;
Object _encodeRules(List<PermissionRule> value) => permissionRulesToJson(value);
bool _noRules(List<PermissionRule> value) => value.isEmpty;

const _approveModeCodec = JsonCodec<ApproveMode>(
  _decodeApproveMode,
  _encodeEnum,
);
const _providersCodec = JsonCodec<List<LlmProviderConfig>>(
  _decodeProviders,
  _encodeProviders,
  empty: _noProviders,
);
const _profileCodec = JsonCodec<Profile>(
  _decodeProfile,
  _encodeProfile,
  empty: _emptyProfile,
);
const _rulesCodec = JsonCodec<List<PermissionRule>>(
  _decodeRules,
  _encodeRules,
  empty: _noRules,
);

/// Every value the settings documents hold, by the key it is kept under.
/// One declaration per key: a level that may set it is in its [Setting.scopes],
/// and the app's level answers for the rest.
abstract final class SettingKeys {
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

  /// Auto-compact's defaults: on, at eighty percent — low enough that the
  /// summary itself and the turn that follows still fit above the window.
  static const defaultAutoCompact = true;

  static const defaultAutoCompactPercent = 80;

  static const autoCompactPercentStops = [60, 70, 80, 90];

  /// The window the guess lands on: 128k sits under every hosted window
  /// today — underestimating costs an early compaction, overestimating costs
  /// a failed request, so the safe guess is the small one.
  static const defaultTotalContext = 256000;

  /// The bounds Total Context is clamped to, at load and at the settings
  /// row's save — two sites that must agree, named once.
  static const minTotalContext = 1024;

  static const maxTotalContext = 1000000000;

  /// The reply length a model with no known limit gets, and the cap's
  /// starting point: the 8192 every Anthropic request used to send.
  static const defaultResponseLength = 8192;

  /// The bounds Maximum response length is clamped to, at load and at the
  /// settings row's save.
  static const minResponseLength = 1024;

  static const maxResponseLength = 1000000;

  /// The default when nothing is set: on, at ten prefixes. A named constant so
  /// the UI's "Default (10)" label and the provider's effective count are one
  /// number.
  static const defaultKvCachePrompts = 10;

  static const defaultModelId = Setting<String>(
    "defaultModelId",
    StringCodec(),
  );

  static const defaultProviderId = Setting<String>(
    "defaultProviderId",
    StringCodec(),
  );

  /// What names a chat after its first message. Both halves or neither: with
  /// nothing here the feature is off and a chat keeps the name it was made
  /// with.
  static const titleModelId = Setting<String>("titleModelId", StringCodec());

  static const titleProviderId = Setting<String>(
    "titleProviderId",
    StringCodec(),
  );

  /// What classifies a command as safe enough to run without asking, when
  /// [approveMode] is [ApproveMode.auto]. Both halves or neither: with nothing
  /// here auto mode falls back to asking for every command.
  static const classifierModelId = Setting<String>(
    "classifierModelId",
    StringCodec(),
  );

  static const classifierProviderId = Setting<String>(
    "classifierProviderId",
    StringCodec(),
  );

  /// What answers `image_generation`, and whether the agent is offered it at
  /// all: no provider is off, the default, since every call is a paid request.
  /// Both halves or neither, as the title's.
  static const imageModelId = Setting<String>("imageModelId", StringCodec());

  static const imageProviderId = Setting<String>(
    "imageProviderId",
    StringCodec(),
  );

  static const imageQuality = DefaultedSetting<ImageQuality>(
    "imageQuality",
    EnumCodec(ImageQuality.values),
    fallback: ImageQuality.auto,
  );

  /// How long the chat LLM thinks, where it is a model that reasons. Sent to
  /// no other: a model that does not reason may refuse the field.
  static const reasoningEffort = DefaultedSetting<ReasoningEffort>(
    "reasoningEffort",
    EnumCodec(ReasoningEffort.values),
    scopes: {SettingScope.app, SettingScope.chat},
    fallback: ReasoningEffort.auto,
  );

  /// The models starred in a picker, in the order they were starred: what its
  /// Favourites section lists, for every role that can use one.
  static const favouriteModels = DefaultedSetting<List<ModelRef>>(
    "favouriteModels",
    ModelRefListCodec(),
    fallback: <ModelRef>[],
  );

  /// Whether `@path` references inside an AGENTS.md pull in more files. The
  /// files themselves are read into every turn; this and [nestedInstructions]
  /// only reach further than the two of them.
  static const instructionImports = DefaultedSetting<bool>(
    "instructionImports",
    BoolCodec(),
    fallback: true,
  );

  /// Whether reading a file pulls the AGENTS.md of each directory above it,
  /// up to the filesystem root, into the turn.
  static const nestedInstructions = DefaultedSetting<bool>(
    "nestedInstructions",
    BoolCodec(),
    fallback: true,
  );

  /// Glob patterns that keep an AGENTS.md out of a turn: a file whose path
  /// one of them names is skipped, wherever the load meets it; empty skips
  /// nothing.
  static const instructionExcludes = DefaultedSetting<List<String>>(
    "instructionExcludes",
    StringListCodec(),
    fallback: <String>[],
  );

  /// Whether the auto-memory subsystem runs: a per-project store of markdown
  /// memories the agent reads, recalls and writes with a background model.
  /// Off by default, and inert beside it until [memoryModelId] is set.
  static const autoMemory = DefaultedSetting<bool>(
    "autoMemory",
    BoolCodec(),
    fallback: false,
  );

  /// What writes memories in the background (extraction after a turn,
  /// consolidation between chats). Both halves or neither: with nothing here
  /// auto-memory stays read-only — nothing is written on the user's behalf
  /// by a model they have not chosen.
  static const memoryModelId = Setting<String>("memoryModelId", StringCodec());

  static const memoryProviderId = Setting<String>(
    "memoryProviderId",
    StringCodec(),
  );

  /// Whether relevant memories are recalled into each turn. A sub-gate of
  /// [autoMemory], on by default: the store is read-only from the turn's point
  /// of view, so the cost is prompt size, capped.
  static const memoryRecall = DefaultedSetting<bool>(
    "memoryRecall",
    BoolCodec(),
    fallback: true,
  );

  /// Whether a background model writes memories from a turn after it ends.
  /// A sub-gate of [autoMemory], on by default, inert beside it until
  /// [memoryModelId] is set.
  static const memoryExtraction = DefaultedSetting<bool>(
    "memoryExtraction",
    BoolCodec(),
    fallback: true,
  );

  /// Whether the agent is offered the `memorySave` and `memorySearch` tools.
  /// A sub-gate of [autoMemory], on by default: a memory it decides to keep is
  /// one it judged worth keeping, rather than one a background pass guessed at.
  static const memoryAgentTool = DefaultedSetting<bool>(
    "memoryAgentTool",
    BoolCodec(),
    fallback: true,
  );

  /// Environment variables the agent's commands run under, and that a provider
  /// may name instead of holding its key. Held here rather than in the shell
  /// because the settings page edits them.
  static const environment = DefaultedSetting<Map<String, String>>(
    "environment",
    StringMapCodec(),
    scopes: {SettingScope.app, SettingScope.project},
    fallback: <String, String>{},
    legacy: _opencodeEnv,
    retired: ["opencodeEnv"],
  );

  /// How the agent handles a command before it runs. A chat can override it.
  /// Default [ApproveMode.auto].
  static const approveMode = DefaultedSetting<ApproveMode>(
    "approveMode",
    _approveModeCodec,
    scopes: {SettingScope.app, SettingScope.chat},
    fallback: ApproveMode.auto,
    legacy: approveModeFromJson,
    retired: ["approveCommands"],
  );

  /// The endpoints the agent can call. Empty until the user adds one, which is
  /// why the first thing settings offers is a list of presets.
  static const llmProviders = DefaultedSetting<List<LlmProviderConfig>>(
    "llmProviders",
    _providersCodec,
    fallback: <LlmProviderConfig>[],
  );

  /// The user's profile, injected at the end of the system prompt. App-level
  /// default; a project can override it. Null means nothing is injected.
  static const profile = Setting<Profile>("profile", _profileCodec);

  /// How the agent words its replies. App-level default; a project can
  /// override it. [Tone.none] adds nothing to the prompt.
  static const tone = DefaultedSetting<Tone>(
    "tone",
    EnumCodec(Tone.values),
    scopes: {SettingScope.app, SettingScope.project},
    fallback: Tone.none,
  );

  /// Whether the agent numbers the web pages a reply drew on and lists them
  /// at the end of it. It names what it used, never a search it was not
  /// asked to make. App-level default; a project can override it.
  static const citations = DefaultedSetting<bool>(
    "citations",
    BoolCodec(),
    scopes: {SettingScope.app, SettingScope.project},
    fallback: false,
  );

  /// Which palette the app draws. App-level only: a palette is the app's,
  /// not a chat's.
  static const appTheme = DefaultedSetting<AppTheme>(
    "appTheme",
    EnumCodec(AppTheme.values),
    fallback: AppTheme.system,
  );

  /// The two colours the palette is built from: the primary is the seed, and
  /// the secondary seeds the accent group beside it. Both indigo is the app's
  /// own scheme, where the secondary is whatever Material derives from the one
  /// seed. App-level, like the theme and the icon.
  static const primaryColour = DefaultedSetting<ThemeColour>(
    "primaryColour",
    EnumCodec(ThemeColour.values),
    fallback: ThemeColour.apple,
  );

  static const secondaryColour = DefaultedSetting<ThemeColour>(
    "secondaryColour",
    EnumCodec(ThemeColour.values),
    fallback: ThemeColour.apple,
  );

  /// How round the corners the theme rounds are — fields, dialogs, menus,
  /// sheets and buttons.
  static const cornerRadius = DefaultedSetting<CornerRadius>(
    "cornerRadius",
    EnumCodec(CornerRadius.values),
    fallback: CornerRadius.medium,
  );

  /// Whether the palette comes from the system instead of the two colours
  /// above — Android's Material 3 Expressive, which follows the wallpaper.
  /// Ignored where the platform has no accent to give.
  static const systemPalette = DefaultedSetting<bool>(
    "systemPalette",
    BoolCodec(),
    fallback: false,
  );

  /// Whether the new-chat screen offers a chip per `/skill` and `@agent` the
  /// library holds. Off, the row is absent from the screen rather than a
  /// blank one, and the composer's menus are the only place those are named.
  /// App-level only, like the theme and the icon.
  static const showCommandChips = DefaultedSetting<bool>(
    "showCommandChips",
    BoolCodec(),
    fallback: false,
  );

  /// How long a temporary chat lives once its TTL is enabled. App-level
  /// default; a project and a chat can override it. [TempChatTtl.off] means
  /// temporary chats are off — chats live forever.
  static const tempChatTtl = DefaultedSetting<TempChatTtl>(
    "tempChatTtl",
    EnumCodec(TempChatTtl.values),
    scopes: {SettingScope.app, SettingScope.project, SettingScope.chat},
    fallback: TempChatTtl.off,
  );

  /// Which voice models listen and speak, and which of a multi-voice model's
  /// speakers is used. A model id is the on-device catalog's where its
  /// provider is [localProviderId], as a picker offers it, and that
  /// provider's own otherwise. App-level only, like the icon and
  /// the theme: a voice is the app's, not a conversation's. Either being null
  /// is voice mode not set up yet, which is what takes the button off the
  /// composer.
  static const voiceRecognitionModelId = Setting<String>(
    "voiceRecognitionModelId",
    StringCodec(),
  );

  static const voiceSpeechModelId = Setting<String>(
    "voiceSpeechModelId",
    StringCodec(),
  );

  static const voiceSpeaker = DefaultedSetting<int>(
    "voiceSpeaker",
    IntCodec(),
    fallback: 0,
  );

  static const voiceRecognitionProviderId = DefaultedSetting<String>(
    "voiceRecognitionProviderId",
    StringCodec(),
    fallback: localProviderId,
  );

  static const voiceSpeechProviderId = DefaultedSetting<String>(
    "voiceSpeechProviderId",
    StringCodec(),
    fallback: localProviderId,
  );

  /// The provider's own name for the voice its speech model reads in, sent as
  /// is. Null sends none, which some providers refuse.
  static const voiceSpeechVoice = Setting<String>(
    "voiceSpeechVoice",
    StringCodec(),
  );

  /// Which language the device's own engines are asked to hear and speak in,
  /// as a BCP-47 tag. Null is the device's own — see `Voice.systemLanguages`.
  static const voiceLanguage = Setting<String>("voiceLanguage", StringCodec());

  /// Whether the microphone is open only while a button is held. Off is voice
  /// mode listening for as long as it is on screen, which is what it is for;
  /// on is for a room where that does not work — a recogniser transcribes
  /// whatever is loud enough, and somewhere noisy enough the only reliable
  /// answer is for the user to say when.
  static const voicePushToTalk = DefaultedSetting<bool>(
    "voicePushToTalk",
    BoolCodec(),
    fallback: false,
  );

  /// Which project the system's assistant gesture opens a chat in. Null is the
  /// default project, the same null `selectedProjectProvider` uses. App-level:
  /// the assistant is the app's, not a conversation's. See issue #54.
  static const assistantProject = Setting<String>(
    "assistantProject",
    StringCodec(),
  );

  /// Which view the assistant gesture opens. App-level, for the same reason.
  static const assistantView = DefaultedSetting<AssistantView>(
    "assistantView",
    EnumCodec(AssistantView.values),
    fallback: AssistantView.chat,
  );

  /// The Linux the agent's commands run inside, by catalog id. Null is Android
  /// itself, which is where every command ran before there was anything else to
  /// run one in — and so what an existing `settings.json` already says by
  /// saying nothing. App-level: which machine the agent is on is the app's, and
  /// a chat moved between the two mid-conversation would be a conversation
  /// about a filesystem that is no longer there.
  static const rootfsId = Setting<String>("rootfsId", StringCodec());

  /// How many on-device models may be loaded at once, capped at
  /// [maxLocalModelsAllowed]. One is the default because each is a process
  /// holding a set of weights and a gigabyte of KV cache; two is what makes a
  /// small model naming chats beside a large one answering them worth setting,
  /// and is what stops the two evicting each other turn after turn.
  static const maxLocalModels = DefaultedSetting<int>(
    "maxLocalModels",
    IntCodec(min: 1, max: maxLocalModelsAllowed),
    fallback: 1,
  );

  /// The accelerator it is offloaded to, by the name `--list-devices` gave it.
  /// Null is auto — the best one the phone turned out to have — and
  /// `LocalDevice.cpu` is how the picker rules them all out. Stored as the name
  /// rather than as a kind, because that is the string the server is passed and
  /// a phone can have two of the same kind.
  static const localModelDevice = Setting<String>(
    "localModelDevice",
    StringCodec(),
  );

  /// How much context every on-device model is loaded with, or null to let each
  /// one answer for itself — `LocalModel.defaultContext`, which is what its own
  /// KV cache costs divided into [kvBudgetBytes]. Set here, it overrides that
  /// for all of them, which is the honest shape now that any downloaded model
  /// can be the one a turn asks for.
  static const localModelContext = Setting<int>(
    "localModelContext",
    IntCodec(),
  );

  /// Whether to warm an on-device model's system-prompt KV in the background
  /// when it is set as a default, so the first chat does not pay the whole
  /// prompt at once. Off by default: it is minutes of the CPU on a phone, so it
  /// is the user's to ask for. See "Prefilling the system prompt" in
  /// `lib/data/local/AGENTS.md`.
  static const localModelPrefill = DefaultedSetting<bool>(
    "localModelPrefill",
    BoolCodec(),
    fallback: false,
  );

  /// How many CPU cores the model server may run on, or null for the default —
  /// every big core (`bigCoreCount`). Lowering it trades tokens-per-second for
  /// battery, which is the only reason to. Read per launch, so a change reaches
  /// the next server rather than the running one.
  static const localModelThreads = Setting<int>(
    "localModelThreads",
    IntCodec(),
  );

  /// How many prompt prefixes the on-device provider keeps warmed on disk, so
  /// reopening a chat restores its KV rather than reprocessing it. Null is the
  /// default (10) and `0` is off — nothing is written.
  ///
  /// One prompt is one request to the model, so it is neither per chat nor per
  /// turn: a turn writes one for each step it takes, and the bound is over
  /// every chat at once. It was called `Chats` and counted neither. See
  /// "Persisting the KV cache to disk" in `lib/data/local/AGENTS.md`.
  static const localModelKvCachePrompts = Setting<int>(
    "localModelKvCachePrompts",
    IntCodec(),
    legacy: _kvCacheChats,
    retired: ["localModelKvCacheChats"],
  );

  /// This device's name as paired devices see it. Null falls back to
  /// "Entoli " plus a fingerprint prefix in [SyncHub].
  static const deviceName = Setting<String>("deviceName", StringCodec());

  /// A user-supplied WebSocket relay endpoint for pairing over the internet.
  /// Empty or null means relay is off and only LAN / manual paste work.
  static const syncRelayUrl = Setting<String>("syncRelayUrl", StringCodec());

  /// Whether a connected peer holds the process open off screen, as a
  /// foreground service with a notification naming the connected devices and
  /// a Disconnect action. Off by default: the cost is a wake lock and a
  /// persistent notification for as long as a device is connected. Android
  /// only; a no-op everywhere a foreground service cannot be started.
  static const syncKeepAlive = DefaultedSetting<bool>(
    "syncKeepAlive",
    BoolCodec(),
    fallback: false,
  );

  /// TURN server URL for NAT traversal. Bring-your-own; STUN defaults are
  /// public. Null means no TURN, so symmetric-NAT pairs fail honestly.
  static const turnUrl = Setting<String>("turnUrl", StringCodec());

  /// TURN credentials, stored beside the URL. Null where the TURN server
  /// needs none (rare) or none is configured. The password is not here: it is
  /// a secret, and lives in the [AppSecrets] store beside the sync identity.
  static const turnUsername = Setting<String>("turnUsername", StringCodec());

  /// How many times a turn that died on a retryable error — a connection that
  /// dropped, a provider hiccup — is carried on automatically before it is
  /// left failed. `0` is off: the turn stops where it failed and the Continue
  /// bar is the only way on. App-level, like the model default it sits beside.
  static const turnRetries = DefaultedSetting<int>(
    "turnRetries",
    IntCodec(min: 0, max: maxTurnRetries),
    fallback: defaultTurnRetries,
  );

  /// Whether a new project starts with Omada on, so the user who wants a
  /// workspace of teams does not flip the toggle per project. Baked into the
  /// project at creation; existing projects and the built-ins are untouched.
  static const omadaByDefault = DefaultedSetting<bool>(
    "omadaByDefault",
    BoolCodec(),
    fallback: false,
  );

  /// How many handoff generations one Omada round may run — dispatch waves,
  /// not turns: a three-member fan-out is one generation. The user's message
  /// is generation one and uncapped; this bounds the waves that follow, and
  /// the user speaking resets the count. A project's
  /// `ProjectSettings.omadaMaxGenerations` overrides it per project.
  static const omadaMaxGenerations = DefaultedSetting<int>(
    "omadaMaxGenerations",
    IntCodec(),
    scopes: {SettingScope.app, SettingScope.project},
    fallback: defaultOmadaMaxGenerations,
  );

  /// The room's scheduling default for a project that picked none of its own:
  /// sequential runs the schedule one turn at a time, parallel answers with
  /// one turn per member at once, and relay answers what a reply names the
  /// moment it is written — per member still one turn at a time, but with no
  /// wave barrier between the waves. `ProjectSettings.omadaOrdering` overrides
  /// it per project; when neither names one the round runs relay. The enum
  /// lives with the project settings, where a per-project answer was first
  /// written.
  static const omadaOrdering = Setting<OmadaOrdering>(
    "omadaOrdering",
    EnumCodec(OmadaOrdering.values),
    scopes: {SettingScope.app, SettingScope.project},
  );

  /// How many model calls one turn may make before it stops for the user —
  /// the step limit the backend runs under. Null is the backend's own
  /// default; the value rides every turn, an Omada member turn included,
  /// and the round's own bound is `omadaMaxGenerations` beside it.
  static const turnMaxSteps = Setting<int>(
    "turnMaxSteps",
    IntCodec(),
    scopes: {SettingScope.app, SettingScope.project},
  );

  /// Whether the conversation is summarized when it grows past
  /// [autoCompactPercent] of the model's window — the auto half of compaction,
  /// which bounds a long chat without a prompt of its own. The manual half is
  /// `/compact`, and needs nothing here.
  static const autoCompact = DefaultedSetting<bool>(
    "autoCompact",
    BoolCodec(),
    fallback: defaultAutoCompact,
  );

  /// The share of the context window auto-compact acts at. A named constant
  /// so the settings row's "Default (80%)" and the controller's check are one
  /// number.
  static const autoCompactPercent = DefaultedSetting<int>(
    "autoCompactPercent",
    IntCodec(min: 10, max: 95),
    fallback: defaultAutoCompactPercent,
  );

  /// The most context a chat is let grow to, in tokens: the window
  /// [autoCompactPercent] is a share of is the model's own or this, whichever
  /// is smaller, and this where the catalog does not know the model — so a
  /// million-token model compacts at a share of this rather than at 800k, a
  /// context no model reads well. The summarizer's own ask is held to the
  /// model's real window where it is known, this only where it is not. The
  /// constant is the row's "(256k)" and the check's number both.
  static const totalContext = DefaultedSetting<int>(
    "totalContext",
    IntCodec(min: minTotalContext, max: maxTotalContext),
    fallback: defaultTotalContext,
  );

  /// Whether every reply is held to [responseLength], over what models.dev
  /// says each model can write. Off, [responseLength] is only the fallback
  /// for a model whose own limit is not known.
  static const capResponseLength = DefaultedSetting<bool>(
    "capResponseLength",
    BoolCodec(),
    fallback: false,
  );

  /// The most tokens one reply may run to: the cap where
  /// [capResponseLength] is on, and the limit a model with no known one gets
  /// where it is off. See "How long a reply may be" in
  /// `lib/data/builtin/llm/AGENTS.md`.
  static const responseLength = DefaultedSetting<int>(
    "responseLength",
    IntCodec(min: minResponseLength, max: maxResponseLength),
    fallback: defaultResponseLength,
  );

  /// Whether the welcome tour was finished with its licence ticked: what first
  /// launch reads to decide whether to show the tour, and what its Done
  /// writes. It replaced `welcomeSeen`, which a file from before still
  /// carries and nothing reads, so those installs walk the tour once more.
  static const licenceAccepted = DefaultedSetting<bool>(
    "licenceAccepted",
    BoolCodec(),
    fallback: false,
  );

  /// Whether the app checks the latest release at startup and puts the newer
  /// build in place of this one, where the platform can do that — the three
  /// desktops are, and each sees the row. Default on, and written only when
  /// off, so a settings file from before it existed says nothing and gets the
  /// on default. See `app_update.dart` for what the check does.
  static const autoUpdate = DefaultedSetting<bool>(
    "autoUpdate",
    BoolCodec(),
    fallback: true,
  );

  /// Whether iOS and macOS draw the app's chrome — the sidebar, a chat's bar
  /// and composer, the new-chat and voice pages — in Apple's own controls and
  /// glass, a SwiftUI shell around the Flutter that draws the conversation.
  /// Read once at launch, since the shell owns the window before any page is
  /// built: a change waits for a restart. Default on and written only when
  /// off, as [autoUpdate] is.
  static const liquidGlass = DefaultedSetting<bool>(
    "liquidGlass",
    BoolCodec(),
    fallback: true,
  );

  /// The browser the agent drives: null off, `embedded` for the downloaded
  /// Helium, or a Chromium-family executable's path. On the phones the
  /// WebView is on by default: null and `webview` are on, `off` is off. See
  /// "The browser" in `lib/data/builtin/AGENTS.md`.
  static const agentBrowser = Setting<String>("agentBrowser", StringCodec());

  /// Whether that browser runs with a window. Hidden by default, with its
  /// user agent cleared of "Headless"; the agent can still show it for the
  /// user to finish a check.
  static const agentBrowserVisible = DefaultedSetting<bool>(
    "agentBrowserVisible",
    BoolCodec(),
    fallback: false,
  );

  /// Who is asked before the browser's agent opens a page or acts on one.
  /// Nobody by default: picking a browser is the consent.
  static const agentBrowserApproval = DefaultedSetting<BrowserApproval>(
    "agentBrowserApproval",
    EnumCodec(BrowserApproval.values),
    fallback: BrowserApproval.never,
  );

  /// Who picks what the agent uploads: its own scope, so the user can take
  /// uploads from the agent and leave it everything else.
  static const agentBrowserUploads = DefaultedSetting<BrowserUploadPolicy>(
    "agentBrowserUploads",
    EnumCodec(BrowserUploadPolicy.values),
    fallback: BrowserUploadPolicy.classifier,
  );

  // A project's and a chat's own.

  /// Whether the project keeps an auto-memory store of its own: inherit
  /// shares the default project's.
  static const memory = Setting<Tristate>(
    "memory",
    EnumCodec(Tristate.values),
    scopes: {SettingScope.project},
    legacy: _useProjectMemory,
    retired: ["useProjectMemory"],
  );

  /// Whether this project's chats can carry several agents in one round. A
  /// user project's toggle; a built-in's answer is its spec, in code. Written
  /// only when on.
  static const omada = Setting<bool>(
    "omada",
    BoolCodec(),
    scopes: {SettingScope.project},
  );

  /// What the new-chat screen asks over the project's badge. Empty is a
  /// value here, the screen asking nothing, where absent is the app default.
  static const description = Setting<String>(
    "description",
    StringCodec(keepEmpty: true),
    scopes: {SettingScope.project},
  );

  /// The command rules a project or a chat adds to the app's.
  static const permissions = Setting<List<PermissionRule>>(
    "permissions",
    _rulesCodec,
    scopes: {SettingScope.project, SettingScope.chat},
  );

  /// The machine paths every turn may write to. See "Work folders" in
  /// `lib/ui/settings/AGENTS.md`.
  static const writableDirs = Setting<List<String>>(
    "writableDirs",
    StringListCodec(),
    scopes: {SettingScope.project, SettingScope.chat},
  );

  /// Whether commands on the machine run under Landlock at all. Unset
  /// inherits, and the app's default is on. A guest's rootfs is its own
  /// boundary and this does not reach it.
  static const sandbox = Setting<bool>(
    "sandbox",
    BoolCodec(),
    scopes: {SettingScope.project, SettingScope.chat},
  );

  /// The chat's own model and the provider it is reached through: both or
  /// neither, unset following the project's and the app's default.
  static const model = Setting<String>(
    "model",
    StringCodec(),
    scopes: {SettingScope.chat},
  );
  static const provider = Setting<String>(
    "provider",
    StringCodec(),
    scopes: {SettingScope.chat},
  );

  /// Whether this chat keeps out of the auto-memory: the recall, the
  /// extraction and the memory tools. The instruction files keep reaching it.
  /// Unset follows the project, and a project that takes the subsystem away
  /// cannot be given it back from here.
  static const memoryOff = Setting<bool>(
    "memoryOff",
    BoolCodec(),
    scopes: {SettingScope.chat},
  );

  /// A chat nobody watches — a trigger's new one. Every turn on it drops
  /// `ask_user` and `task`, since nobody is there to answer or to need the
  /// fan-out, and suppresses the title model, since a trigger already named
  /// the chat.
  static const headless = Setting<bool>(
    "headless",
    BoolCodec(),
    scopes: {SettingScope.chat},
  );

  /// The keys whose files may still hold them under an old name.
  static const upgrades = <Setting>[
    environment,
    approveMode,
    localModelKvCachePrompts,
    memory,
  ];
}
