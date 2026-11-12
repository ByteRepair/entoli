import "dart:convert";

import "../core/config.dart";
import "agent_browser.dart" show BrowserApproval, BrowserUploadPolicy;
import "app_theme.dart";
import "assistant_view.dart";
import "corner_radius.dart";
import "llm_provider.dart";
import "model_capability.dart" show ModelRef;
import "model_options.dart";
import "omada_ordering.dart";
import "permission.dart";
import "profile.dart";
import "settings/keys.dart";
import "settings/setting.dart";
import "temp_chat_ttl.dart";
import "theme_colour.dart";
import "tone.dart";

export "model_options.dart";

/// The app's own settings, : a typed view of its document.
/// What each value is, how it is kept and what it falls back to is its
/// declaration in [SettingKeys]; a value here is one line over that.
class AppSettings {
  AppSettings({
    String? defaultModelId,
    String? defaultProviderId,
    String? titleModelId,
    String? titleProviderId,
    String? classifierModelId,
    String? classifierProviderId,
    String? imageModelId,
    String? imageProviderId,
    ImageQuality? imageQuality,
    ReasoningEffort? reasoningEffort,
    List<ModelRef>? favouriteModels,
    bool? instructionImports,
    bool? nestedInstructions,
    List<String>? instructionExcludes,
    bool? autoMemory,
    String? memoryModelId,
    String? memoryProviderId,
    bool? memoryRecall,
    bool? memoryExtraction,
    bool? memoryAgentTool,
    Map<String, String>? environment,
    ApproveMode? approveMode,
    List<LlmProviderConfig>? llmProviders,
    Profile? profile,
    Tone? tone,
    bool? citations,
    AppTheme? appTheme,
    ThemeColour? primaryColour,
    ThemeColour? secondaryColour,
    CornerRadius? cornerRadius,
    bool? systemPalette,
    bool? showCommandChips,
    TempChatTtl? tempChatTtl,
    String? voiceRecognitionModelId,
    String? voiceSpeechModelId,
    int? voiceSpeaker,
    String? voiceRecognitionProviderId,
    String? voiceSpeechProviderId,
    String? voiceSpeechVoice,
    String? voiceLanguage,
    bool? voicePushToTalk,
    String? assistantProject,
    AssistantView? assistantView,
    String? rootfsId,
    int? maxLocalModels,
    String? localModelDevice,
    int? localModelContext,
    bool? localModelPrefill,
    int? localModelThreads,
    int? localModelKvCachePrompts,
    String? deviceName,
    String? syncRelayUrl,
    bool? syncKeepAlive,
    String? turnUrl,
    String? turnUsername,
    int? turnRetries,
    bool? omadaByDefault,
    int? omadaMaxGenerations,
    OmadaOrdering? omadaOrdering,
    int? turnMaxSteps,
    bool? autoCompact,
    int? autoCompactPercent,
    int? totalContext,
    bool? capResponseLength,
    int? responseLength,
    bool? licenceAccepted,
    bool? autoUpdate,
    bool? liquidGlass,
    String? agentBrowser,
    bool? agentBrowserVisible,
    BrowserApproval? agentBrowserApproval,
    BrowserUploadPolicy? agentBrowserUploads,
  }) : doc = SettingsDocument(root: true) {
    doc
      ..set(SettingKeys.defaultModelId, defaultModelId)
      ..set(SettingKeys.defaultProviderId, defaultProviderId)
      ..set(SettingKeys.titleModelId, titleModelId)
      ..set(SettingKeys.titleProviderId, titleProviderId)
      ..set(SettingKeys.classifierModelId, classifierModelId)
      ..set(SettingKeys.classifierProviderId, classifierProviderId)
      ..set(SettingKeys.imageModelId, imageModelId)
      ..set(SettingKeys.imageProviderId, imageProviderId)
      ..set(SettingKeys.imageQuality, imageQuality)
      ..set(SettingKeys.reasoningEffort, reasoningEffort)
      ..set(SettingKeys.favouriteModels, favouriteModels)
      ..set(SettingKeys.instructionImports, instructionImports)
      ..set(SettingKeys.nestedInstructions, nestedInstructions)
      ..set(SettingKeys.instructionExcludes, instructionExcludes)
      ..set(SettingKeys.autoMemory, autoMemory)
      ..set(SettingKeys.memoryModelId, memoryModelId)
      ..set(SettingKeys.memoryProviderId, memoryProviderId)
      ..set(SettingKeys.memoryRecall, memoryRecall)
      ..set(SettingKeys.memoryExtraction, memoryExtraction)
      ..set(SettingKeys.memoryAgentTool, memoryAgentTool)
      ..set(SettingKeys.environment, environment)
      ..set(SettingKeys.approveMode, approveMode)
      ..set(SettingKeys.llmProviders, llmProviders)
      ..set(SettingKeys.profile, profile)
      ..set(SettingKeys.tone, tone)
      ..set(SettingKeys.citations, citations)
      ..set(SettingKeys.appTheme, appTheme)
      ..set(SettingKeys.primaryColour, primaryColour)
      ..set(SettingKeys.secondaryColour, secondaryColour)
      ..set(SettingKeys.cornerRadius, cornerRadius)
      ..set(SettingKeys.systemPalette, systemPalette)
      ..set(SettingKeys.showCommandChips, showCommandChips)
      ..set(SettingKeys.tempChatTtl, tempChatTtl)
      ..set(SettingKeys.voiceRecognitionModelId, voiceRecognitionModelId)
      ..set(SettingKeys.voiceSpeechModelId, voiceSpeechModelId)
      ..set(SettingKeys.voiceSpeaker, voiceSpeaker)
      ..set(SettingKeys.voiceRecognitionProviderId, voiceRecognitionProviderId)
      ..set(SettingKeys.voiceSpeechProviderId, voiceSpeechProviderId)
      ..set(SettingKeys.voiceSpeechVoice, voiceSpeechVoice)
      ..set(SettingKeys.voiceLanguage, voiceLanguage)
      ..set(SettingKeys.voicePushToTalk, voicePushToTalk)
      ..set(SettingKeys.assistantProject, assistantProject)
      ..set(SettingKeys.assistantView, assistantView)
      ..set(SettingKeys.rootfsId, rootfsId)
      ..set(SettingKeys.maxLocalModels, maxLocalModels)
      ..set(SettingKeys.localModelDevice, localModelDevice)
      ..set(SettingKeys.localModelContext, localModelContext)
      ..set(SettingKeys.localModelPrefill, localModelPrefill)
      ..set(SettingKeys.localModelThreads, localModelThreads)
      ..set(SettingKeys.localModelKvCachePrompts, localModelKvCachePrompts)
      ..set(SettingKeys.deviceName, deviceName)
      ..set(SettingKeys.syncRelayUrl, syncRelayUrl)
      ..set(SettingKeys.syncKeepAlive, syncKeepAlive)
      ..set(SettingKeys.turnUrl, turnUrl)
      ..set(SettingKeys.turnUsername, turnUsername)
      ..set(SettingKeys.turnRetries, turnRetries)
      ..set(SettingKeys.omadaByDefault, omadaByDefault)
      ..set(SettingKeys.omadaMaxGenerations, omadaMaxGenerations)
      ..set(SettingKeys.omadaOrdering, omadaOrdering)
      ..set(SettingKeys.turnMaxSteps, turnMaxSteps)
      ..set(SettingKeys.autoCompact, autoCompact)
      ..set(SettingKeys.autoCompactPercent, autoCompactPercent)
      ..set(SettingKeys.totalContext, totalContext)
      ..set(SettingKeys.capResponseLength, capResponseLength)
      ..set(SettingKeys.responseLength, responseLength)
      ..set(SettingKeys.licenceAccepted, licenceAccepted)
      ..set(SettingKeys.autoUpdate, autoUpdate)
      ..set(SettingKeys.liquidGlass, liquidGlass)
      ..set(SettingKeys.agentBrowser, agentBrowser)
      ..set(SettingKeys.agentBrowserVisible, agentBrowserVisible)
      ..set(SettingKeys.agentBrowserApproval, agentBrowserApproval)
      ..set(SettingKeys.agentBrowserUploads, agentBrowserUploads);
  }

  AppSettings.of(this.doc);

  final SettingsDocument doc;

  String? get defaultModelId => doc.read(SettingKeys.defaultModelId);
  set defaultModelId(String? value) =>
      doc.set(SettingKeys.defaultModelId, value);

  String? get defaultProviderId => doc.read(SettingKeys.defaultProviderId);
  set defaultProviderId(String? value) =>
      doc.set(SettingKeys.defaultProviderId, value);

  String? get titleModelId => doc.read(SettingKeys.titleModelId);
  set titleModelId(String? value) => doc.set(SettingKeys.titleModelId, value);

  String? get titleProviderId => doc.read(SettingKeys.titleProviderId);
  set titleProviderId(String? value) =>
      doc.set(SettingKeys.titleProviderId, value);

  String? get classifierModelId => doc.read(SettingKeys.classifierModelId);
  set classifierModelId(String? value) =>
      doc.set(SettingKeys.classifierModelId, value);

  String? get classifierProviderId =>
      doc.read(SettingKeys.classifierProviderId);
  set classifierProviderId(String? value) =>
      doc.set(SettingKeys.classifierProviderId, value);

  String? get imageModelId => doc.read(SettingKeys.imageModelId);
  set imageModelId(String? value) => doc.set(SettingKeys.imageModelId, value);

  String? get imageProviderId => doc.read(SettingKeys.imageProviderId);
  set imageProviderId(String? value) =>
      doc.set(SettingKeys.imageProviderId, value);

  ImageQuality get imageQuality => doc.of(SettingKeys.imageQuality);
  set imageQuality(ImageQuality value) =>
      doc.set(SettingKeys.imageQuality, value);

  ReasoningEffort get reasoningEffort => doc.of(SettingKeys.reasoningEffort);
  set reasoningEffort(ReasoningEffort value) =>
      doc.set(SettingKeys.reasoningEffort, value);

  List<ModelRef> get favouriteModels => doc.of(SettingKeys.favouriteModels);
  set favouriteModels(List<ModelRef> value) =>
      doc.set(SettingKeys.favouriteModels, value);

  bool get instructionImports => doc.of(SettingKeys.instructionImports);
  set instructionImports(bool value) =>
      doc.set(SettingKeys.instructionImports, value);

  bool get nestedInstructions => doc.of(SettingKeys.nestedInstructions);
  set nestedInstructions(bool value) =>
      doc.set(SettingKeys.nestedInstructions, value);

  List<String> get instructionExcludes =>
      doc.of(SettingKeys.instructionExcludes);
  set instructionExcludes(List<String> value) =>
      doc.set(SettingKeys.instructionExcludes, value);

  bool get autoMemory => doc.of(SettingKeys.autoMemory);
  set autoMemory(bool value) => doc.set(SettingKeys.autoMemory, value);

  String? get memoryModelId => doc.read(SettingKeys.memoryModelId);
  set memoryModelId(String? value) => doc.set(SettingKeys.memoryModelId, value);

  String? get memoryProviderId => doc.read(SettingKeys.memoryProviderId);
  set memoryProviderId(String? value) =>
      doc.set(SettingKeys.memoryProviderId, value);

  bool get memoryRecall => doc.of(SettingKeys.memoryRecall);
  set memoryRecall(bool value) => doc.set(SettingKeys.memoryRecall, value);

  bool get memoryExtraction => doc.of(SettingKeys.memoryExtraction);
  set memoryExtraction(bool value) =>
      doc.set(SettingKeys.memoryExtraction, value);

  bool get memoryAgentTool => doc.of(SettingKeys.memoryAgentTool);
  set memoryAgentTool(bool value) =>
      doc.set(SettingKeys.memoryAgentTool, value);

  Map<String, String> get environment => doc.of(SettingKeys.environment);
  set environment(Map<String, String> value) =>
      doc.set(SettingKeys.environment, value);

  ApproveMode get approveMode => doc.of(SettingKeys.approveMode);
  set approveMode(ApproveMode value) => doc.set(SettingKeys.approveMode, value);

  List<LlmProviderConfig> get llmProviders => doc.of(SettingKeys.llmProviders);
  set llmProviders(List<LlmProviderConfig> value) =>
      doc.set(SettingKeys.llmProviders, value);

  Profile? get profile => doc.read(SettingKeys.profile);
  set profile(Profile? value) => doc.set(SettingKeys.profile, value);

  Tone get tone => doc.of(SettingKeys.tone);
  set tone(Tone value) => doc.set(SettingKeys.tone, value);

  bool get citations => doc.of(SettingKeys.citations);
  set citations(bool value) => doc.set(SettingKeys.citations, value);

  AppTheme get appTheme => doc.of(SettingKeys.appTheme);
  set appTheme(AppTheme value) => doc.set(SettingKeys.appTheme, value);

  ThemeColour get primaryColour => doc.of(SettingKeys.primaryColour);
  set primaryColour(ThemeColour value) =>
      doc.set(SettingKeys.primaryColour, value);

  ThemeColour get secondaryColour => doc.of(SettingKeys.secondaryColour);
  set secondaryColour(ThemeColour value) =>
      doc.set(SettingKeys.secondaryColour, value);

  CornerRadius get cornerRadius => doc.of(SettingKeys.cornerRadius);
  set cornerRadius(CornerRadius value) =>
      doc.set(SettingKeys.cornerRadius, value);

  bool get systemPalette => doc.of(SettingKeys.systemPalette);
  set systemPalette(bool value) => doc.set(SettingKeys.systemPalette, value);

  bool get showCommandChips => doc.of(SettingKeys.showCommandChips);
  set showCommandChips(bool value) =>
      doc.set(SettingKeys.showCommandChips, value);

  TempChatTtl get tempChatTtl => doc.of(SettingKeys.tempChatTtl);
  set tempChatTtl(TempChatTtl value) => doc.set(SettingKeys.tempChatTtl, value);

  String? get voiceRecognitionModelId =>
      doc.read(SettingKeys.voiceRecognitionModelId);
  set voiceRecognitionModelId(String? value) =>
      doc.set(SettingKeys.voiceRecognitionModelId, value);

  String? get voiceSpeechModelId => doc.read(SettingKeys.voiceSpeechModelId);
  set voiceSpeechModelId(String? value) =>
      doc.set(SettingKeys.voiceSpeechModelId, value);

  int get voiceSpeaker => doc.of(SettingKeys.voiceSpeaker);
  set voiceSpeaker(int value) => doc.set(SettingKeys.voiceSpeaker, value);

  String get voiceRecognitionProviderId =>
      doc.of(SettingKeys.voiceRecognitionProviderId);
  set voiceRecognitionProviderId(String value) =>
      doc.set(SettingKeys.voiceRecognitionProviderId, value);

  String get voiceSpeechProviderId => doc.of(SettingKeys.voiceSpeechProviderId);
  set voiceSpeechProviderId(String value) =>
      doc.set(SettingKeys.voiceSpeechProviderId, value);

  String? get voiceSpeechVoice => doc.read(SettingKeys.voiceSpeechVoice);
  set voiceSpeechVoice(String? value) =>
      doc.set(SettingKeys.voiceSpeechVoice, value);

  String? get voiceLanguage => doc.read(SettingKeys.voiceLanguage);
  set voiceLanguage(String? value) => doc.set(SettingKeys.voiceLanguage, value);

  bool get voicePushToTalk => doc.of(SettingKeys.voicePushToTalk);
  set voicePushToTalk(bool value) =>
      doc.set(SettingKeys.voicePushToTalk, value);

  String? get assistantProject => doc.read(SettingKeys.assistantProject);
  set assistantProject(String? value) =>
      doc.set(SettingKeys.assistantProject, value);

  AssistantView get assistantView => doc.of(SettingKeys.assistantView);
  set assistantView(AssistantView value) =>
      doc.set(SettingKeys.assistantView, value);

  String? get rootfsId => doc.read(SettingKeys.rootfsId);
  set rootfsId(String? value) => doc.set(SettingKeys.rootfsId, value);

  int get maxLocalModels => doc.of(SettingKeys.maxLocalModels);
  set maxLocalModels(int value) => doc.set(SettingKeys.maxLocalModels, value);

  String? get localModelDevice => doc.read(SettingKeys.localModelDevice);
  set localModelDevice(String? value) =>
      doc.set(SettingKeys.localModelDevice, value);

  int? get localModelContext => doc.read(SettingKeys.localModelContext);
  set localModelContext(int? value) =>
      doc.set(SettingKeys.localModelContext, value);

  bool get localModelPrefill => doc.of(SettingKeys.localModelPrefill);
  set localModelPrefill(bool value) =>
      doc.set(SettingKeys.localModelPrefill, value);

  int? get localModelThreads => doc.read(SettingKeys.localModelThreads);
  set localModelThreads(int? value) =>
      doc.set(SettingKeys.localModelThreads, value);

  int? get localModelKvCachePrompts =>
      doc.read(SettingKeys.localModelKvCachePrompts);
  set localModelKvCachePrompts(int? value) =>
      doc.set(SettingKeys.localModelKvCachePrompts, value);

  String? get deviceName => doc.read(SettingKeys.deviceName);
  set deviceName(String? value) => doc.set(SettingKeys.deviceName, value);

  String? get syncRelayUrl => doc.read(SettingKeys.syncRelayUrl);
  set syncRelayUrl(String? value) => doc.set(SettingKeys.syncRelayUrl, value);

  bool get syncKeepAlive => doc.of(SettingKeys.syncKeepAlive);
  set syncKeepAlive(bool value) => doc.set(SettingKeys.syncKeepAlive, value);

  String? get turnUrl => doc.read(SettingKeys.turnUrl);
  set turnUrl(String? value) => doc.set(SettingKeys.turnUrl, value);

  String? get turnUsername => doc.read(SettingKeys.turnUsername);
  set turnUsername(String? value) => doc.set(SettingKeys.turnUsername, value);

  int get turnRetries => doc.of(SettingKeys.turnRetries);
  set turnRetries(int value) => doc.set(SettingKeys.turnRetries, value);

  bool get omadaByDefault => doc.of(SettingKeys.omadaByDefault);
  set omadaByDefault(bool value) => doc.set(SettingKeys.omadaByDefault, value);

  int get omadaMaxGenerations => doc.of(SettingKeys.omadaMaxGenerations);
  set omadaMaxGenerations(int value) =>
      doc.set(SettingKeys.omadaMaxGenerations, value);

  OmadaOrdering? get omadaOrdering => doc.read(SettingKeys.omadaOrdering);
  set omadaOrdering(OmadaOrdering? value) =>
      doc.set(SettingKeys.omadaOrdering, value);

  int? get turnMaxSteps => doc.read(SettingKeys.turnMaxSteps);
  set turnMaxSteps(int? value) => doc.set(SettingKeys.turnMaxSteps, value);

  bool get autoCompact => doc.of(SettingKeys.autoCompact);
  set autoCompact(bool value) => doc.set(SettingKeys.autoCompact, value);

  int get autoCompactPercent => doc.of(SettingKeys.autoCompactPercent);
  set autoCompactPercent(int value) =>
      doc.set(SettingKeys.autoCompactPercent, value);

  int get totalContext => doc.of(SettingKeys.totalContext);
  set totalContext(int value) => doc.set(SettingKeys.totalContext, value);

  bool get capResponseLength => doc.of(SettingKeys.capResponseLength);
  set capResponseLength(bool value) =>
      doc.set(SettingKeys.capResponseLength, value);

  int get responseLength => doc.of(SettingKeys.responseLength);
  set responseLength(int value) => doc.set(SettingKeys.responseLength, value);

  bool get licenceAccepted => doc.of(SettingKeys.licenceAccepted);
  set licenceAccepted(bool value) =>
      doc.set(SettingKeys.licenceAccepted, value);

  bool get autoUpdate => doc.of(SettingKeys.autoUpdate);
  set autoUpdate(bool value) => doc.set(SettingKeys.autoUpdate, value);

  bool get liquidGlass => doc.of(SettingKeys.liquidGlass);
  set liquidGlass(bool value) => doc.set(SettingKeys.liquidGlass, value);

  String? get agentBrowser => doc.read(SettingKeys.agentBrowser);
  set agentBrowser(String? value) => doc.set(SettingKeys.agentBrowser, value);

  bool get agentBrowserVisible => doc.of(SettingKeys.agentBrowserVisible);
  set agentBrowserVisible(bool value) =>
      doc.set(SettingKeys.agentBrowserVisible, value);

  BrowserApproval get agentBrowserApproval =>
      doc.of(SettingKeys.agentBrowserApproval);
  set agentBrowserApproval(BrowserApproval value) =>
      doc.set(SettingKeys.agentBrowserApproval, value);

  BrowserUploadPolicy get agentBrowserUploads =>
      doc.of(SettingKeys.agentBrowserUploads);
  set agentBrowserUploads(BrowserUploadPolicy value) =>
      doc.set(SettingKeys.agentBrowserUploads, value);

  /// Whether a provider other than [exceptId] is called [name], whatever its
  /// case: a name is what tells two of them apart.
  bool providerNameTaken(String name, {String? exceptId}) {
    final lower = name.trim().toLowerCase();
    return llmProviders.any(
      (p) => p.id != exceptId && p.displayName.toLowerCase() == lower,
    );
  }

  static const defaultTurnRetries = SettingKeys.defaultTurnRetries;
  static const maxTurnRetries = SettingKeys.maxTurnRetries;
  static const defaultOmadaMaxGenerations =
      SettingKeys.defaultOmadaMaxGenerations;
  static const omadaGenerationStops = SettingKeys.omadaGenerationStops;
  static const turnStepStops = SettingKeys.turnStepStops;
  static const defaultTurnMaxSteps = SettingKeys.defaultTurnMaxSteps;
  static const defaultAutoCompact = SettingKeys.defaultAutoCompact;
  static const defaultAutoCompactPercent =
      SettingKeys.defaultAutoCompactPercent;
  static const autoCompactPercentStops = SettingKeys.autoCompactPercentStops;
  static const defaultTotalContext = SettingKeys.defaultTotalContext;
  static const minTotalContext = SettingKeys.minTotalContext;
  static const maxTotalContext = SettingKeys.maxTotalContext;
  static const defaultResponseLength = SettingKeys.defaultResponseLength;
  static const minResponseLength = SettingKeys.minResponseLength;
  static const maxResponseLength = SettingKeys.maxResponseLength;
  static const defaultKvCachePrompts = SettingKeys.defaultKvCachePrompts;

  static AppSettings load(AppConfig config) {
    final text = config.documents.read(config.settingsFile);
    if (text == null) return AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(text) as Map<String, dynamic>);
    } catch (_) {
      return AppSettings();
    }
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings.of(
    SettingsDocument(json: json, root: true, upgrades: SettingKeys.upgrades),
  );

  /// A fresh instance holding the same values, for a notifier that has to hand
  /// out a new object to be noticed. The values are mutable, so a caller
  /// changes them with a cascade.
  AppSettings copy() => AppSettings.of(doc.copy());

  Future<void> save(AppConfig config) =>
      config.documents.write(config.settingsFile, jsonEncode(toJson()));

  Map<String, dynamic> toJson() => doc.toJson();
}

/// How the tools write: the settings notifier's own update, so a change lands
/// in the state the app holds rather than under it.
typedef SettingsEditor =
    Future<void> Function(void Function(AppSettings) change);
