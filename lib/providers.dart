import "dart:async";

import "package:clock/clock.dart";
import "package:flutter/foundation.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;
import "package:http/http.dart" as http;
import "package:uuid/uuid.dart";

import "../core/config.dart";
import "domain/file_tools.dart" show resolveWorkspacePath;
import "../core/platform/platform.dart"
    show createFileWatches, createPromptSources, setupComplete;
import "data/builtin/builtin_backend.dart";
import "data/local/file_trigger_store.dart";
import "data/prompts/agent_pictures.dart";
import "domain/app_icon.dart";
import "domain/agent_backend.dart";
import "domain/app_restart.dart";
import "domain/app_secrets.dart";
import "domain/app_settings.dart";
import "domain/app_update.dart";
import "domain/app_theme.dart";
import "domain/assistant_launch.dart";
import "domain/assistant_view.dart";
import "domain/attachment_picker.dart";
import "domain/backup_handoff.dart";
import "domain/background_work.dart";
import "domain/builtin_project.dart";
import "domain/chat_repository.dart";
import "domain/corner_radius.dart";
import "domain/chat_store.dart";
import "domain/file_handoff.dart";
import "domain/link_opener.dart";
import "domain/llm_provider.dart";
import "data/builtin/llm/local_prefill.dart";
import "data/local/byte_repair_store.dart";
import "domain/local_llm.dart";
import "domain/local_model.dart";
import "domain/local_model_store.dart";
import "domain/models.dart";
import "data/prompts/prompt_sources.dart" show promptTiers;
import "domain/permission.dart";
import "domain/profile.dart";
import "domain/project_settings.dart";
import "domain/project.dart" show ProjectRef, emptyChatQuestionFor, everyProject;
import "domain/prompt_library.dart";
import "domain/reminder_alarms.dart";
import "domain/trigger.dart";
import "domain/trigger_kinds.dart";
import "domain/trigger_runner.dart";
import "domain/trigger_manager.dart";
import "domain/rootfs_store.dart";
import "domain/shell.dart";
import "data/builtin/memory/store.dart" show Memories, MemoryStore;
import "data/sync/sync_hub.dart";
import "data/sync/sync_keep_alive.dart";
import "domain/temp_chat_ttl.dart";
import "domain/theme_colour.dart";
import "domain/tone.dart";
import "domain/tristate.dart";
import "domain/turn_keep_alive.dart";
import "domain/voice.dart";
import "domain/voice_model.dart"
    show RecognitionModel, SpeechModel, voiceModelOf;
import "domain/voice_model_store.dart";

final chatStoreProvider = Provider<ChatStore>((ref) => throw UnimplementedError());
final agentBackendProvider = Provider<AgentBackend>((ref) => throw UnimplementedError());
final shellProvider = Provider<Shell>((ref) => throw UnimplementedError());

/// Where the shell for [workspace] is standing, live: what the composer's bar
/// draws while a `!` command is being typed. [workspaceHome] is the project
/// workspace the turns are handed as their home, only what the shell needs to
/// word the guest's own fallback for it. Null where there is no workspace to
/// ask about, or the shell holds no session for one — which the composer
/// falls back to the guest's view of the workspace itself for.
final chatShellCwdProvider = Provider.family<ValueListenable<String?>?,
    ({String? workspace, String? workspaceHome})>((ref, key) {
  final workspace = key.workspace;
  if (workspace == null) return null;
  return ref
      .watch(shellProvider)
      .sessionCwd(workspace, home: key.workspaceHome);
});
final appConfigProvider = Provider<AppConfig>((ref) => throw UnimplementedError());

/// The client the marketplace's fetches ride. An override in tests, so the
/// suite answers the URLs rather than the binding's all-400s stand-in.
final marketplaceClientProvider =
    Provider<http.Client>((ref) => throw UnimplementedError());
final attachmentPickerProvider = Provider<AttachmentPicker>((ref) => throw UnimplementedError());
final fileHandoffProvider = Provider<FileHandoff>((ref) => throw UnimplementedError());
final backupHandoffProvider = Provider<BackupHandoff>((ref) => throw UnimplementedError());
final appRestartProvider = Provider<AppRestart>((ref) => throw UnimplementedError());
final voiceProvider = Provider<Voice>((ref) => throw UnimplementedError());
final assistantLaunchProvider =
    Provider<AssistantLaunch>((ref) => throw UnimplementedError());
final voiceModelStoreProvider =
    Provider<VoiceModelStore>((ref) => throw UnimplementedError());

/// Which models a pick can name and get something that works: what is on disk,
/// plus the system-engine sentinels on a device that has those engines. One set
/// rather than a set and a question beside it — every gate here asks "is this
/// pick usable", and a second mechanism for the native half would be a second
/// thing each of them had to remember.
///
/// Read once before the app is built and kept in step after that by whatever
/// installs or deletes one — the bargain [promptLibraryProvider] makes, for the
/// reason it makes it. Asked lazily this is a disk scan and a channel call, and
/// until they answered every reader would be told "none": a button drawn from
/// it would be drawn wrong for those frames, and a button's callback, which
/// reads rather than watches, would be wrong on the first press however long
/// the app had been open.
class InstalledVoiceModels extends InstalledIds {
  InstalledVoiceModels(super.seed, {this.system = const {}});

  /// The sentinels this device can honour. Held rather than folded into the
  /// seed, because a re-scan reads the store and would otherwise drop them.
  /// What a device with no engines answers is an empty set — see
  /// [Voice.hasEngineInstalls] for the platform question the missing-engine
  /// block is drawn from instead.
  final Set<String> system;

  @override
  Future<Set<String>> scan() async =>
      {...await ref.read(voiceModelStoreProvider).installed(), ...system};
}

/// Which of a catalog's ids are installed and whole: seeded before the app is
/// built, and [refresh]ed by whatever installs or deletes one — the only thing
/// that changes the answer. A lazy scan would draw every row "not installed"
/// first.
abstract class InstalledIds extends Notifier<Set<String>> {
  InstalledIds(this._seed);

  final Set<String> _seed;

  @override
  Set<String> build() => _seed;

  Future<Set<String>> scan();

  Future<void> refresh() async {
    final installed = await scan();
    if (ref.mounted) state = installed;
  }
}

final installedVoiceModelsProvider =
    NotifierProvider<InstalledVoiceModels, Set<String>>(
        () => InstalledVoiceModels(const {}));

final rootfsStoreProvider = Provider<RootfsStore>((ref) => throw UnimplementedError());

/// Which distributions are installed, for the Terminal page's rows.
class InstalledRootfs extends InstalledIds {
  InstalledRootfs(super.seed);

  @override
  Future<Set<String>> scan() => ref.read(rootfsStoreProvider).installed();
}

final installedRootfsProvider =
    NotifierProvider<InstalledRootfs, Set<String>>(() => InstalledRootfs(const {}));

/// The Byte Repair tooling store, overridden in `main` with one that knows the
/// cache directory. Throws until then, the way `rootfsStoreProvider` does.
final byteRepairStoreProvider =
    Provider<ByteRepairStore>((ref) => throw UnimplementedError());

/// The version of each tool the setup installs (ESBMC, make, gh), or null
/// where one is not installed. Refreshed by the settings page after a setup run.
///
/// Gated on setup being complete: before it there is no environment to probe
/// — the poll would run inside the shared base rootfs, the wrong instance for
/// a project that isolates its own, and write proot's stubs into it where the
/// next setup's copy died on them. "Not installed" with no shell run is the
/// honest row.
final byteRepairToolVersionsProvider =
    FutureProvider<Map<String, String?>>((ref) async {
  if (!ref.watch(setupCompleteProvider(ByteRepairProject().dir))) {
    return {for (final tool in ByteRepairStore.tools.keys) tool: null};
  }
  final store = ref.watch(byteRepairStoreProvider);
  final shell = ref.watch(shellProvider);
  return store.runToolVersions(shell);
});

/// Whether a project requiring setup has been set up. True for projects that
/// don't require setup (the common case); for one that does, asks the platform
/// about the `.setup-complete` marker in the project's directory. Invalidated
/// by the settings page after Run Setup or Delete.
///
/// The marker, the host's binary check and the guests' env question are the
/// platform side's (`platformSetupComplete`) — this watch is only for
/// *rebuilds* on an env change, so switching the Terminal settings' pick
/// moves the bar without a marker write.
final setupCompleteProvider =
    Provider.family<bool, String?>((ref, project) {
  final spec = builtinProjectOf(project);
  if (spec?.requiresSetup != true) return true;
  ref.watch(appSettingsProvider.select((s) => s.rootfsId));
  return setupComplete(ref.watch(appConfigProvider), project,
      ref.watch(byteRepairBinDirProvider));
});

/// Where Byte Repair's fetched tools land on the host — the directory both
/// the turns' driver injects on PATH and `setupComplete` asks after. Resolved
/// once in `main` beside the cache directory; null where there is none.
final byteRepairBinDirProvider = Provider<String?>((ref) => null);

final localModelStoreProvider =
    Provider<LocalModelStore>((ref) => const UnavailableLocalModelStore());

/// The server that answers from this device, and nothing where no build of one
/// reached it. Overridden in `main`, since resolving the binary is a channel
/// round trip and every reader of this is synchronous.
final localLlmProvider = Provider<LocalLlm>((ref) => const UnavailableLocalLlm());

/// Which on-device models are downloaded.
class InstalledLocalModels extends InstalledIds {
  InstalledLocalModels(super.seed);

  @override
  Future<Set<String>> scan() => ref.read(localModelStoreProvider).installed();
}

final installedLocalModelsProvider =
    NotifierProvider<InstalledLocalModels, Set<String>>(
        () => InstalledLocalModels(const {}));

/// What is loaded on the device and how far each one has got. A notifier over
/// the port's own [ValueListenable] rather than a second copy of the state:
/// what starts a model is a turn asking for one, so the settings page is
/// watching something it did not start.
class LocalLlmStatus extends Notifier<List<LocalLlmState>>
    with ListenableValue {
  @override
  List<LocalLlmState> build() => bridge(ref.watch(localLlmProvider).running);
}

final localLlmStateProvider =
    NotifierProvider<LocalLlmStatus, List<LocalLlmState>>(LocalLlmStatus.new);

/// The on-device prompt warm-up, or null where there is no server to warm
/// against — every platform but Android, and an Android whose build shipped no
/// model server. Overridden in `main`, where the shell that words the system
/// prompt and the foreground service that shows its notification both are.
final localPrefillProvider = Provider<LocalPrefill?>((ref) => null);

/// What the warm-up is doing, for the settings page to draw. A notifier over
/// the port's own [ValueListenable], like [localLlmStateProvider] beside it.
class LocalPrefillStatus extends Notifier<LocalPrefillState?>
    with ListenableValue {
  @override
  LocalPrefillState? build() {
    final prefill = ref.watch(localPrefillProvider);
    return prefill == null ? null : bridge(prefill.state);
  }
}

final localPrefillStateProvider =
    NotifierProvider<LocalPrefillStatus, LocalPrefillState?>(LocalPrefillStatus.new);

/// Drives the warm-up from the settings that decide it: when the default model
/// is a downloaded on-device one and prefill is on, warm it; anything else
/// calls it off. Read once at startup, like [turnKeepAliveProvider] — it sets
/// up its listeners rather than rebuilding, so it keeps reacting when nothing
/// is watching it.
final localPrefillTriggerProvider = Provider<void>((ref) {
  final prefill = ref.watch(localPrefillProvider);
  if (prefill == null) return;
  void sync() {
    final target = _prefillTarget(
      ref.read(appSettingsProvider),
      ref.read(installedLocalModelsProvider),
    );
    if (target != null) {
      prefill.warm(target);
    } else {
      prefill.cancel();
    }
  }

  ref.listen(appSettingsProvider, (_, _) => sync());
  ref.listen(installedLocalModelsProvider, (_, _) => sync());
  sync();
});

/// The model to warm, or null when nothing should be: the default model, where
/// it is a downloaded on-device one and the user has asked for this.
String? _prefillTarget(AppSettings settings, Set<String> installed) {
  if (!settings.localModelPrefill) return null;
  if (settings.defaultProviderId != localProviderId) return null;
  final id = settings.defaultModelId;
  if (id == null || !installed.contains(id)) return null;
  return id;
}

/// Which architecture this install is for, and so which rootfs a download
/// fetches. Read once at startup — it cannot change while the app runs. Android
/// is the only thing that answers, so a null one is also how a page tells a
/// phone from a desktop.
final deviceAbiProvider = Provider<String?>((ref) => null);

/// What About says this build is. Read once at startup beside the ABI, and null
/// where the bundle would not answer — see `appVersion` in `core/platform/`.
final appVersionProvider = Provider<String?>((ref) => null);

/// Whether this build can run a command inside a Linux at all: proot has to
/// have been packaged for the device's ABI. False everywhere but Android — and
/// on an Android whose APK was built without it, which the Terminal page says
/// rather than describing a device that cannot run one.
final prootAvailableProvider = Provider<bool>((ref) => false);

/// What this build can do about a newer release of itself: the three desktops
/// answer with the real platform half, everything else is the one that cannot.
/// Overridden in `main` beside the rest of the platform ports.
final appUpdateHostProvider = Provider<AppUpdateHost>(
    (ref) => const UnavailableAppUpdateHost());

/// Whether a message can be read out: a platform that can speak, and a speech
/// model picked and installed. Half of [voiceReadyProvider], because reading a
/// message out needs nothing to hear with.
final speechReadyProvider = Provider<bool>((ref) {
  if (!ref.watch(voiceProvider).available) return false;
  final settings = ref.watch(appSettingsProvider);
  // `contains` takes an `Object?`, so a setting naming nothing is simply not
  // in the set. A sentinel is in it only where the device has the engine, so
  // a settings file carried off a phone does not light up read-aloud on a
  // machine that cannot speak.
  return ref.watch(installedVoiceModelsProvider).contains(
      voiceModelOf<SpeechModel>(settings.voiceSpeechModelId)?.id);
});

/// Whether the composer draws its voice button: a platform that can listen, and
/// two models picked and installed. Anything less and pressing it could only
/// lead to an apology.
final voiceReadyProvider = Provider<bool>((ref) {
  if (!ref.watch(speechReadyProvider)) return false;
  final settings = ref.watch(appSettingsProvider);
  return ref.watch(installedVoiceModelsProvider).contains(
      voiceModelOf<RecognitionModel>(settings.voiceRecognitionModelId)?.id);
});

/// The languages the device's own engines offer. A future rather than
/// something seeded at startup like [installedVoiceModelsProvider]: only the
/// settings page reads it, and answering it on Android means starting a
/// synthesiser to ask.
final systemVoiceLanguagesProvider =
    FutureProvider<List<VoiceLanguage>>((ref) => ref.watch(voiceProvider).systemLanguages());

/// The prompt library, per project: the default's is the base set every other
/// project inherits, and a project's own overrides a same-named default entry
/// for that project alone. Built once at startup and rebuilt only where
/// something on screen says the disk changed — the Skills page, importing or
/// deleting one. See "Skills and agents" in `lib/domain/AGENTS.md` for why it
/// is otherwise read once: nothing downstream waits on it, and a file added
/// behind the app's back reaches the next launch.
///
/// `null` is the default project, the way it is everywhere a project is named.
/// A project not yet seeded (one created after launch) falls back to the
/// default's library, which is exactly what it should resolve to until it has
/// overrides of its own — and the first `reload` builds its real one.
class PromptLibraryNotifier extends Notifier<PromptLibrary> {
  PromptLibraryNotifier(this.project, [this._initial]);

  final String? project;
  final PromptLibrary? _initial;

  @override
  PromptLibrary build() {
    final seeded = _initial;
    if (seeded != null) return seeded;
    if (project == null) return PromptLibrary.empty;
    // An unseeded project inherits the default's set, which is what it
    // resolves to until it has overrides of its own.
    return ref.read(promptLibraryProvider(null));
  }

  /// Read the sources again, and hand the backend its copy: the agent holds
  /// one of its own for the `task` tool and the skills it offers a turn.
  Future<void> reload() async {
    final next = await PromptLibrary.from(
        createPromptSources(ref.read(appConfigProvider), project: project));
    state = next;
    final backend = ref.read(agentBackendProvider);
    if (backend is BuiltinBackend) backend.setLibrary(project, next);
  }
}

final promptLibraryProvider =
    NotifierProvider.family<PromptLibraryNotifier, PromptLibrary, String?>(
        (project) => PromptLibraryNotifier(project));

/// Reload every project's library at once. The Skills page and a skill install
/// touch the default's directory (and possibly a project's), so a change has to
/// land everywhere rather than in the one the page happens to be looking at.
/// The project list comes from the cached [projectListProvider] rather than a
/// fresh directory walk, and the per-project reloads overlap since each reads
/// its own dir.
Future<void> reloadAllPromptLibraries(WidgetRef ref) async {
  final named = await ref.read(projectListProvider.future);
  await Future.wait(everyProject(named).map((project) =>
      ref.read(promptLibraryProvider(project).notifier).reload()));
}

class AppSettingsNotifier extends Notifier<AppSettings> {
  late final AppConfig _config;

  @override
  AppSettings build() {
    _config = ref.watch(appConfigProvider);
    final loaded = AppSettings.load(_config);
    // The device's own engines are the default where it has them — voice mode
    // works the moment the app is installed, with nothing to download. Each
    // side is defaulted on its own, so a phone with a synthesiser and no
    // recognition pick gets the half it can do and leaves the other
    // unpicked, rather than a pick that fails when it is pressed.
    //
    // A settings file that already names a model, sherpa or native, is left as
    // it is: this only fills a null, the way "no pick" used to read. Not saved
    // either, so the file stays as it was until the user picks something and
    // one carried to a machine without the engines means "no pick" again.
    // The device's engines rather than the whole usable set: what a download
    // adds is never a sentinel, so watching the set would rebuild these
    // settings every time a model was fetched or deleted — and this `build`
    // may only run once, since `_config` is initialised in it.
    final system = ref.read(installedVoiceModelsProvider.notifier).system;
    final picks = ref.read(voiceProvider).nativePicks;
    if (system.isEmpty || picks == null) return loaded;
    final defaulted = loaded.copy();
    if (system.contains(picks.recognition)) {
      defaulted.voiceRecognitionModelId ??= picks.recognition;
    }
    if (system.contains(picks.speech)) {
      defaulted.voiceSpeechModelId ??= picks.speech;
    }
    return defaulted;
  }

  /// What a new chat is answered by, or nothing at all.
  Future<void> setDefault(ModelChoice choice) => _update((s) => s
    ..defaultProviderId = choice.providerId
    ..defaultModelId = choice.modelId);

  /// What names a new chat, or nothing at all.
  Future<void> setTitleModel(ModelChoice choice) => _update((s) => s
    ..titleProviderId = choice.providerId
    ..titleModelId = choice.modelId);

  /// What classifies commands when auto mode is on, or nothing at all.
  Future<void> setClassifierModel(ModelChoice choice) => _update((s) => s
    ..classifierProviderId = choice.providerId
    ..classifierModelId = choice.modelId);

  /// Read when a command runs, so an edit reaches the next one.
  Future<void> setEnvironment(Map<String, String> env) =>
      _update((s) => s.environment = Map.unmodifiable(env));

  Future<void> setApproveMode(ApproveMode value) =>
      _update((s) => s.approveMode = value);

  /// How many times a retryable turn failure is carried on automatically.
  Future<void> setTurnRetries(int value) => _update((s) => s.turnRetries = value);

  /// Whether a new project starts with Omada on.
  Future<void> setOmadaByDefault(bool value) =>
      _update((s) => s.omadaByDefault = value);

  /// How many handoff generations one Omada round may run, app-wide.
  Future<void> setOmadaMaxGenerations(int value) =>
      _update((s) => s.omadaMaxGenerations = value);

  /// The room's scheduling default for projects that picked none of their own.
  Future<void> setOmadaOrdering(OmadaOrdering? value) =>
      _update((s) => s.omadaOrdering = value);

  /// The step limit a direct turn runs under; null is the backend's default.
  Future<void> setTurnMaxSteps(int? value) =>
      _update((s) => s.turnMaxSteps = value);

  /// Whether the conversation is summarized at [setAutoCompactPercent]'s
  /// share of the window. The manual `/compact` needs nothing here.
  Future<void> setAutoCompact(bool value) =>
      _update((s) => s.autoCompact = value);

  /// The share of the window auto-compact acts at.
  Future<void> setAutoCompactPercent(int value) =>
      _update((s) => s.autoCompactPercent = value);

  /// The model's total context, in tokens — the whole the auto-compact
  /// threshold's share is taken against, and the summarizer's own ceiling.
  Future<void> setTotalContext(int value) =>
      _update((s) => s.totalContext = value);

  /// Whether `@path` references inside an AGENTS.md pull in more files.
  Future<void> setInstructionImports(bool value) =>
      _update((s) => s.instructionImports = value);

  /// Whether reading a file pulls in a subdirectory's own AGENTS.md.
  Future<void> setNestedInstructions(bool value) =>
      _update((s) => s.nestedInstructions = value);

  /// The glob patterns that keep an AGENTS.md out of a turn.
  Future<void> setInstructionExcludes(List<String> value) =>
      _update((s) => s.instructionExcludes = value);

  /// Whether the auto-memory subsystem runs at all.
  Future<void> setAutoMemory(bool value) =>
      _update((s) => s.autoMemory = value);

  /// Whether relevant memories are recalled into each turn. A sub-gate of
  /// [setAutoMemory], on by default.
  Future<void> setMemoryRecall(bool value) =>
      _update((s) => s.memoryRecall = value);

  /// Whether a background model writes memories from a turn after it ends.
  Future<void> setMemoryExtraction(bool value) =>
      _update((s) => s.memoryExtraction = value);

  /// Whether the agent is offered the memory tools.
  Future<void> setMemoryAgentTool(bool value) =>
      _update((s) => s.memoryAgentTool = value);

  /// What writes memories in the background, or nothing at all — until one is
  /// picked, extraction and consolidation stay off.
  Future<void> setMemoryModel(ModelChoice choice) => _update((s) => s
    ..memoryProviderId = choice.providerId
    ..memoryModelId = choice.modelId);

  /// The user's profile (null clears it), how replies are worded, and whether
  /// they number the web pages they drew on: one write, since the profile
  /// page saves all three at once.
  Future<void> setReplyStyle({
    Profile? profile,
    Tone? tone,
    bool? citations,
  }) =>
      _update((s) => s
        ..profile = profile
        ..tone = tone ?? s.tone
        ..citations = citations ?? s.citations);

  /// Setting first, launcher second: a launcher that refuses still leaves the
  /// app showing what was picked.
  Future<void> setAppIcon(AppIcon icon) async {
    await _update((s) => s.appIcon = icon);
    await ref.read(launcherIconsProvider).use(icon);
  }

  Future<void> setAppTheme(AppTheme theme) => _update((s) => s.appTheme = theme);

  Future<void> setPrimaryColour(ThemeColour colour) =>
      _update((s) => s.primaryColour = colour);

  Future<void> setSecondaryColour(ThemeColour colour) =>
      _update((s) => s.secondaryColour = colour);

  Future<void> setCornerRadius(CornerRadius corner) =>
      _update((s) => s.cornerRadius = corner);

  /// Whether the palette follows the system's. The two colours are left where
  /// they were, so turning it off again returns to what was picked.
  Future<void> setSystemPalette(bool follow) =>
      _update((s) => s.systemPalette = follow);

  /// Whether the app replaces itself with a newer release it finds at
  /// startup, where the platform it is on can do that.
  Future<void> setAutoUpdate(bool value) =>
      _update((s) => s.autoUpdate = value);

  /// Which project the assistant gesture opens a chat in. Null is the default
  /// project.
  Future<void> setAssistantProject(String? project) =>
      _update((s) => s.assistantProject = project);

  Future<void> setAssistantView(AssistantView view) =>
      _update((s) => s.assistantView = view);

  Future<void> setVoiceRecognitionModel(String? id) =>
      _update((s) => s.voiceRecognitionModelId = id);

  /// Picking a different voice resets which of its speakers is used: speaker 40
  /// of Kokoro is nobody in a model with eight.
  Future<void> setVoiceSpeechModel(String? id) => _update((s) => s
    ..voiceSpeechModelId = id
    ..voiceSpeaker = 0);

  Future<void> setVoiceSpeaker(int speaker) =>
      _update((s) => s.voiceSpeaker = speaker);

  /// Which language the system engines are asked for, or null for the
  /// device's. It reaches the next session rather than the one running: the
  /// language is in the intent a recognition is started with and in the
  /// synthesiser's own state, both settled when a session is built.
  Future<void> setVoiceLanguage(String? tag) =>
      _update((s) => s.voiceLanguage = tag);

  /// Whether the microphone waits for a button to be held. Reaches a session
  /// already running: the controller listens for it.
  Future<void> setVoicePushToTalk(bool on) =>
      _update((s) => s.voicePushToTalk = on);

  /// Which Linux the agent's commands run inside, or null for Android itself.
  /// It reaches the next command rather than the next turn: the shell resolves
  /// this per command.
  Future<void> setRootfs(String? id) => _update((s) => s.rootfsId = id);

  /// How many may be loaded at once. Lowering it does not stop anything: the
  /// cap is read when a model is asked for, so the extra one goes at the next
  /// turn rather than being killed under a chat that is mid-reply.
  Future<void> setMaxLocalModels(int count) =>
      _applyLocal((s) => s.maxLocalModels = count.clamp(1, maxLocalModelsAllowed));

  /// Which accelerator it is offloaded to, by the name `--list-devices` gave
  /// it. Null is auto.
  Future<void> setLocalDevice(String? device) =>
      _applyLocal((s) => s.localModelDevice = device);

  Future<void> setLocalContext(int? tokens) =>
      _applyLocal((s) => s.localModelContext = tokens);

  Future<void> setLocalPrefill(bool on) =>
      _applyLocal((s) => s.localModelPrefill = on);

  /// How many cores the server runs on, or null for every big core. Reaches the
  /// next server, not the running one — the cap is read when a model loads.
  Future<void> setLocalThreads(int? threads) =>
      _applyLocal((s) => s.localModelThreads = threads);

  /// How many prompt prefixes to keep warmed on disk, null for the default
  /// (ten) and `0` for off.
  Future<void> setLocalKvCachePrompts(int? prompts) =>
      _applyLocal((s) => s.localModelKvCachePrompts = prompts);

  Future<void> setDeviceName(String? name) =>
      _update((s) => s.deviceName = name);

  Future<void> setSyncRelayUrl(String? url) =>
      _update((s) => s.syncRelayUrl = url);

  Future<void> setSyncKeepAlive(bool on) =>
      _update((s) => s.syncKeepAlive = on);

  Future<void> setTurnUrl(String? url) => _update((s) => s.turnUrl = url);

  /// The TURN username is not a secret: it stays in `settings.json` beside the
  /// URL and the retries. The password goes to [setTurnPassword], in the
  /// secret store.
  Future<void> setTurnUsername(String? username) =>
      _update((s) => s.turnUsername = username);

  /// Stored, and then the model list is rebuilt. One field at a time and never
  /// a sibling: threading the others through every setter is what lets a value
  /// a picker is *showing* as Default be silently written back.
  ///
  /// Nothing is started or stopped here. What is running is reconciled against
  /// these when a turn next asks for a model — see [LocalLlm.serve] — so a
  /// device or context changed mid-reply does not pull the model out from under
  /// it.
  Future<void> _applyLocal(void Function(AppSettings) change) async {
    await _update(change);
    ref.invalidate(availableModelsProvider);
  }

  /// How long a temporary chat lives. App-level default; a project and a chat
  /// can override it. Re-anchors every chat to now so the badges appear
  /// immediately and the sidebar filter is current.
  Future<void> setTempChatTtl(TempChatTtl ttl) async {
    await _update((s) => s.tempChatTtl = ttl);
    await ref.read(chatRepositoryProvider).reanchorAllTtl();
    ref.invalidate(chatListProvider);
  }

  /// The endpoints the agent can call, replacing any entry that shares an id.
  /// The model list is rebuilt from them, so it is invalidated here rather
  /// than left showing the old one.
  ///
  /// [setKey] is the key decision in the dialog's own encoding — null leaves
  /// the stored key, `""` clears it, a string stores it — and [fromId] names
  /// the entry this replaces where a rename moved its id: the stored key
  /// follows the new id and the old entry goes, all before the state change
  /// whose rebuild reads the store.
  ///
  /// The first provider ever configured becomes what every still-unset role
  /// resolves to — the same `_update` as the save, so it cannot land half
  /// done — until the user picks something themselves. A role the user has
  /// already picked is left where it is; importing a backup and other bulk
  /// writes stay on [setProviders], which adopts nothing.
  Future<void> upsertProvider(LlmProviderConfig provider,
      {String? fromId, String? setKey}) async {
    // The key first: the settings state change below is what rebuilds the
    // section drawing the row, and the row reads the store — so the key has
    // to be in it before that rebuild runs.
    final secrets = ref.read(appSecretsProvider);
    if (fromId != null && fromId != provider.id) {
      await secrets.setProviderKey(provider.id, setKey ?? secrets.providerKey(fromId));
      await secrets.setProviderKey(fromId, null);
    } else if (setKey != null) {
      await secrets.setProviderKey(provider.id, setKey.isEmpty ? null : setKey);
    }
    final existing = state.llmProviders;
    final isNew = existing.every((p) => p.id != provider.id && p.id != fromId);
    await _update((s) => s
      ..llmProviders = List.unmodifiable([
        ...existing.where((p) => p.id != provider.id && p.id != fromId), provider
      ])
      ..defaultProviderId = s.defaultProviderId ?? (isNew ? provider.id : null)
      ..titleProviderId = s.titleProviderId ?? (isNew ? provider.id : null)
      ..memoryProviderId = s.memoryProviderId ?? (isNew ? provider.id : null)
      ..classifierProviderId =
          s.classifierProviderId ?? (isNew ? provider.id : null));
    ref.invalidate(availableModelsProvider);
  }

  /// The endpoints the agent can call, written as given. The model list is
  /// rebuilt from them, so it is invalidated here rather than left showing
  /// the old one. Bulk and removal writes: no adoption. A provider removed
  /// here takes its stored key with it — nothing else would ever delete it,
  /// and an entry nobody names is a secret kept for no one.
  Future<void> setProviders(List<LlmProviderConfig> providers) async {
    final removed =
        state.llmProviders.map((p) => p.id).toSet()
          ..removeAll(providers.map((p) => p.id));
    // Deleted before the state change, for the same reason the upsert stores
    // first: the rebuild the state change starts reads the store.
    final secrets = ref.read(appSecretsProvider);
    for (final id in removed) {
      await secrets.setProviderKey(id, null);
    }
    await _update((s) => s.llmProviders = List.unmodifiable(providers));
    ref.invalidate(availableModelsProvider);
  }

  /// Whether the welcome tour has been finished, written by its Done.
  Future<void> setWelcomeSeen(bool seen) => _update((s) => s.welcomeSeen = seen);

  /// Change a copy and publish it: the notifier compares by identity, so
  /// editing in place would save the file and update nothing on screen.
  Future<void> _update(void Function(AppSettings) change) async {
    final next = state.copy();
    change(next);
    state = next;
    await next.save(_config);
  }
}

final appSettingsProvider =
    NotifierProvider<AppSettingsNotifier, AppSettings>(AppSettingsNotifier.new);

final launcherIconsProvider =
    Provider<LauncherIcons>((ref) => throw UnimplementedError());

/// The system's own accent, read once in `main` and overridden with what it
/// found. Null is a platform with none, which is what takes the Material 3
/// Expressive switch off the settings page — so the default here is every
/// platform but a recent Android.
final systemAccentProvider = Provider<int?>((ref) => null);

/// The accent the palette is actually built from: the system's, where it has
/// one and the user asked for it. Null is the two colours the settings page
/// offers instead, and is what draws them.
final paletteAccentProvider = Provider<int?>((ref) =>
    ref.watch(appSettingsProvider.select((s) => s.systemPalette))
        ? ref.watch(systemAccentProvider)
        : null);

final linkOpenerProvider =
    Provider<LinkOpener>((ref) => throw UnimplementedError());

/// The provider API keys and the TURN password. Overridden in `main` with the
/// one built over the platform's secret store; faked in tests over a
/// `FakeSecretStore`.
final appSecretsProvider =
    Provider<AppSecrets>((ref) => throw UnimplementedError());

final backgroundWorkProvider =
    Provider<BackgroundWork>((ref) => throw UnimplementedError());

final syncHubProvider = Provider<SyncHub>((ref) => throw UnimplementedError());

/// A [ValueListenable] made watchable: Riverpod has nothing that watches one.
mixin ListenableValue<T> on Notifier<T> {
  T bridge(ValueListenable<T> source) {
    void changed() => state = source.value;
    source.addListener(changed);
    ref.onDispose(() => source.removeListener(changed));
    return source.value;
  }
}

/// One of the hub's `ValueNotifier`s, watchable. The subclasses below name
/// which notifier and nothing else, which is also what lets a test override
/// one without a hub to read.
abstract class HubValue<T> extends Notifier<T> with ListenableValue<T> {
  ValueListenable<T> of(SyncHub hub);

  @override
  T build() => bridge(of(ref.watch(syncHubProvider)));
}

/// The Remotes half of the sidebar: every mirrored chat with who owns it and
/// whether the connection to them is up.
///
/// Deliberately separate from [chatListProvider], which reads the local
/// store and stays sync-unaware: two sources of truth, never merged.
class RemoteChats extends HubValue<List<RemoteChatEntry>> {
  @override
  ValueListenable<List<RemoteChatEntry>> of(SyncHub hub) => hub.remotes;
}

final remoteChatsProvider =
    NotifierProvider<RemoteChats, List<RemoteChatEntry>>(RemoteChats.new);

/// Every device this one has paired with, online or not. One list rather than
/// the registry for membership and the hub for status: a device paired while
/// the Sync page was open landed in the hub and not in the registry read the
/// page was still holding, so it did not appear until the page was left and
/// come back to.
class PairedDevices extends HubValue<Map<String, PeerState>> {
  @override
  ValueListenable<Map<String, PeerState>> of(SyncHub hub) => hub.peers;
}

final syncPeersProvider =
    NotifierProvider<PairedDevices, Map<String, PeerState>>(PairedDevices.new);

/// What each paired device last said its projects are, by device id.
class DeviceProjects extends HubValue<Map<String, List<String>>> {
  @override
  ValueListenable<Map<String, List<String>>> of(SyncHub hub) => hub.deviceProjects;
}

final deviceProjectsProvider =
    NotifierProvider<DeviceProjects, Map<String, List<String>>>(DeviceProjects.new);

/// A paired device's project while something is showing it, and only then:
/// the follow goes with the last watcher, and what was read with it. Null
/// until the device has answered.
class RemoteProjectNotifier extends Notifier<RemoteProject?> {
  RemoteProjectNotifier(this.project);

  final ProjectRef project;

  @override
  RemoteProject? build() {
    final hub = ref.watch(syncHubProvider);
    hub.followProject(project);
    final sub = hub.projectUpdates.where((p) => p == project).listen((_) {
      if (ref.mounted) state = hub.remoteProject(project);
    });
    ref.onDispose(() {
      sub.cancel();
      hub.unfollowProject(project);
    });
    return hub.remoteProject(project);
  }
}

final remoteProjectProvider = NotifierProvider.autoDispose
    .family<RemoteProjectNotifier, RemoteProject?, ProjectRef>(RemoteProjectNotifier.new);

/// Whether [ProjectRef]'s settings are here to show: always for this
/// device's, once its device has answered for a paired one's.
final projectLoadedProvider = Provider.autoDispose.family<bool, ProjectRef>((ref, project) =>
    project.device == null || ref.watch(remoteProjectProvider(project)) != null);

/// A paired device's project its device's listing no longer names: deleted
/// there, so nothing will answer for it. Unknown until a listing has come.
final projectGoneProvider = Provider.autoDispose.family<bool, ProjectRef>((ref, project) {
  if (project.device == null) return false;
  final listed = ref.watch(deviceProjectsProvider.select((d) => d[project.device]));
  return listed != null && !everyProject(listed).contains(project.project);
});

/// A paired device's project whose device is away: what it last said stays
/// readable, and nothing is written until it is back.
final projectFrozenProvider = Provider.family<bool, ProjectRef>((ref, project) =>
    project.device != null &&
    ref.watch(syncPeersProvider.select((peers) => peers[project.device]?.status)) !=
        PeerStatus.online);

final isMirroredChatProvider = Provider.family<bool, String>((ref, chatId) {
  return ref
      .watch(remoteChatsProvider.select((chats) => chats.any((c) => c.chatId == chatId)));
});

/// The single owner of the platform's download slot — see [DownloadHold]. Every
/// catalog's notifier reports through it rather than to [BackgroundWork].
final downloadHoldProvider =
    Provider<DownloadHold>((ref) => DownloadHold(ref.watch(backgroundWorkProvider)));

/// Read once in `main` for its effect: it listens to the backend from the
/// moment it exists, and nothing ever asks it anything. A provider so that its
/// lifetime is the container's and `dispose` has a caller.
final turnKeepAliveProvider = Provider<TurnKeepAlive>((ref) {
  final keepAlive = TurnKeepAlive(
      ref.watch(agentBackendProvider), ref.watch(backgroundWorkProvider));
  ref.onDispose(keepAlive.dispose);
  return keepAlive;
});

final syncKeepAliveProvider = Provider<SyncKeepAlive>((ref) {
  final keepAlive = SyncKeepAlive(
    ref.watch(syncHubProvider),
    ref.watch(backgroundWorkProvider),
    keepAlive: () => ref.read(appSettingsProvider).syncKeepAlive,
  );
  // The keep-alive only hears of the setting when a status moves; the switch
  // itself has to act at once, which is what this listen is for. The
  // subscription dies with the container, as the keep-alive's own does.
  ref.listen(
    appSettingsProvider.select((s) => s.syncKeepAlive),
    (_, _) => keepAlive.refresh(),
  );
  ref.onDispose(keepAlive.dispose);
  return keepAlive;
});

final reminderAlarmsProvider =
    Provider<ReminderAlarms>((ref) => const UnavailableReminderAlarms());

/// Whether the app is out of the user's sight, which a turn's tail reads from
/// outside the widget tree. An `AppLifecycleListener` writes it from the app
/// root.
final appHiddenProvider =
    NotifierProvider<AppHidden, bool>(AppHidden.new);

class AppHidden extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool hidden) => state = hidden;
}

/// The app's clock, read as "now" by whatever needs a swappable time. The
/// system clock in production; tests override it with [Clock.fixed] so a
/// feature that judges dates against "now" — the reminder feature today — is
/// not judged against the wall clock the suite happens to run on.
final clockProvider = Provider<Clock>((ref) => const Clock());

/// The user's triggers, seeded from disk before the container exists and
/// written through on every change — the same bargain [InstalledRootfs] makes.
class Triggers extends Notifier<List<Trigger>> implements TriggerList {
  Triggers(this._seed);

  final List<Trigger> _seed;
  late FileTriggerStore _store;

  @override
  List<Trigger> build() {
    _store = FileTriggerStore(ref.watch(appConfigProvider));
    return _seed;
  }

  @override
  List<Trigger> get triggers => state;

  @override
  Future<void> write(List<Trigger> triggers) async {
    state = triggers;
    await _store.save(triggers);
  }

  @override
  Future<void> replace(Trigger trigger) => write([
        for (final t in state) if (t.id == trigger.id) trigger else t,
      ]);

  /// Add with its alarm request code assigned: the one place codes are handed
  /// out, so they stay unique for the trigger's life.
  Future<void> add(Trigger trigger) => write([
        ...state,
        trigger.copyWith(requestCode: nextRequestCode(state)),
      ]);

  Future<void> remove(String id) =>
      write([for (final t in state) if (t.id != id) t]);

  /// A trigger the tools registered for [chatId], which is its target. The
  /// reload the list change causes puts it under watch the moment it lands.
  ///
  /// A timer is anchored here, where the clock is: the parse carried a
  /// placeholder, and re-anchoring is what makes a countdown thirty seconds
  /// from *this* rather than from somebody else's midnight.
  Future<Trigger> registerFor(String chatId,
      {required TriggerSource source, required String prompt, String? name, String? member}) async {
    final project = await ref.read(chatRepositoryProvider).projectOf(chatId);
    final now = ref.read(clockProvider).now();
    final anchored = source is TimerSource
        ? TimerSource(duration: source.duration, registeredAt: now)
        : source;
    // Refused where the editor refuses it: a born-disarmed one-shot is a
    // success answer that fires nowhere — see [triggerScheduleProblem].
    final problem = triggerScheduleProblem(anchored, now);
    if (problem != null) {
      throw ArgumentError.value(
          (anchored as ScheduleSource).at, "at", problem);
    }
    final draft = Trigger(
      id: const Uuid().v4(),
      name: name ?? "",
      prompt: prompt,
      source: anchored,
      chatId: chatId,
      member: member,
      project: project,
      byAgent: true,
      nextFireAt: anchored.nextAfter(now),
    );
    await add(draft);
    return draft;
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final at = state.indexWhere((t) => t.id == id);
    if (at < 0) return;
    final trigger = state[at];
    final next = enabled
        ? trigger.source.nextAfter(ref.read(clockProvider).now())
        : null;
    // Disabling disarms it; re-enabling recomputes — a file trigger has
    // nothing on the clock to re-arm, a repeating schedule its next
    // occurrence, a one-shot past its time nothing.
    await replace(trigger.copyWith(enabled: enabled, clearNextFireAt: true)
        .copyWith(nextFireAt: next));
  }
}

final triggersProvider =
    NotifierProvider<Triggers, List<Trigger>>(() => Triggers(const []));

/// The file kind's path resolution — `resolveWorkspacePath` over the pair
/// of workspaces the turn's own file tools would resolve against: the
/// same `sharedWorkspace` rule, the same guest translation (a path the
/// model fed back from inside a guest watches on the host where the guest
/// keeps it), the same `~`. A trigger registered by a tool names its own
/// chat, whose workspace exists — the turn ran there; one the user set has
/// no chat, and its relative base is the project's workspace, the directory
/// a chat of its own would share. There are no arguments of the resolver's
/// own to get wrong — everything it passes is what the read tool would be
/// passed, which is the parity the tool schema promises.
String _resolveTriggerPath(
  AppConfig config,
  Shell shell,
  String path,
  String? chatId,
  String? project,
) {
  final chatWorkspace =
      chatId == null ? null : config.workspaceDir(chatId, project: project);
  final shared = builtinProjectOf(project)?.sharedWorkspace ?? true;
  // A chatless trigger in a project whose workspace is not shared (the
  // anonymous one — the editor offers it): there is no chat workspace to
  // stand in for the project's, so the project's directory it is.
  final projectWorkspace = shared
      ? config.projectWorkspaceDir(project: project)
      : (chatWorkspace ?? config.projectWorkspaceDir(project: project));
  return resolveWorkspacePath(
    config.fs,
    path,
    chatWorkspace ?? projectWorkspace,
    projectWorkspace,
    guestRoot: shell.guestRoot,
    homePath: shell.homeFor(projectWorkspace),
  );
}

final triggerTurnDriverProvider =
    Provider<TriggerTurnDriver>((ref) => throw UnimplementedError());

/// Started once beside the sweep timer. It listens to the list from here, so
/// an edit anywhere rebuilds every kind's watch without the editor having to
/// know the kinds exist. The registry — the kinds that exist, in the order
/// they answer the source picker — is built here rather than held as a
/// constant, because each kind takes its port.
final triggerManagerProvider = Provider<TriggerManager>((ref) {
  final alarms = ref.watch(reminderAlarmsProvider);
  final manager = TriggerManager(
    kinds: [
      ClockKind(alarms, matchOf: (t) => t.source is ScheduleSource),
      ClockKind(alarms, matchOf: (t) => t.source is TimerSource),
      FileKind(
        fileWatches: createFileWatches(),
        resolve: (trigger, path) async => _resolveTriggerPath(
          ref.read(appConfigProvider),
          ref.read(shellProvider),
          path,
          trigger.chatId,
          trigger.project,
        ),
      ),
    ],
    alarmPort: alarms,
    runner: TriggerRunner(
      repo: ref.watch(chatRepositoryProvider),
      driver: ref.watch(triggerTurnDriverProvider),
      alarms: alarms,
      onListChanged: (_) => ref.invalidate(chatListProvider),
      onTriggerFired: (trigger) =>
          ref.read(triggersProvider.notifier).replace(trigger),
      clock: ref.watch(clockProvider),
    ),
    list: ref.watch(triggersProvider.notifier),
    projects: () => ref.read(chatRepositoryProvider).listProjects(),
    clock: ref.watch(clockProvider),
  );
  ref.onDispose(manager.dispose);
  ref.listen(triggersProvider, (_, _) {
    unawaited(manager.reload());
  });
  return manager;
});

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  // Deliberately not watching appSettingsProvider: the repository reads the
  // settings when it uses them, so changing a default does not rebuild the
  // repository and re-scan every chat off disk.
  return ChatRepository(
    ref.watch(chatStoreProvider),
    ref.watch(agentBackendProvider),
    () => ref.read(appSettingsProvider),
    ref.watch(appConfigProvider),
    // The library is resolved per project at compose time: the message is
    // composed against the project's library, not an app-wide one — see
    // "Skills and agents" in `lib/domain/AGENTS.md`. Read fresh each time
    // rather than captured, so a reload reaches the next message.
    libraryFor: (project) => ref.read(promptLibraryProvider(project)),
  );
});

/// The sidebar's list: the chats on disk, in every project — each says which
/// one it is in. A new chat joins when its first message is saved, and whoever
/// changes what the list shows invalidates it.
final chatListProvider = FutureProvider<List<ChatState>>(
    (ref) => ref.watch(chatRepositoryProvider).listChats());

/// Keeps the sidebar's list in step with local deletions. The widget that
/// asked for a delete invalidates [chatListProvider] too, but its ref may be
/// gone by the time the await returns; this listens to the repo's `Deleted`
/// event so the row pointing at a chat whose data is gone cannot stay up. Read
/// once at startup to keep the subscription alive for the app's lifetime.
final chatDeletionRefreshProvider = Provider<void>((ref) {
  final repo = ref.watch(chatRepositoryProvider);
  final sub = repo.changes.listen((event) {
    if (event is Deleted) ref.invalidate(chatListProvider);
  });
  ref.onDispose(sub.cancel);
});

/// The projects that exist, for the sidebar's switcher. The default project is
/// not in it: it is null, and it is always there.
final projectListProvider =
    FutureProvider((ref) => ref.watch(chatRepositoryProvider).listProjects());

final availableModelsProvider = FutureProvider<List<ModelOption>>(
    (ref) => ref.watch(agentBackendProvider).models());

/// The same models in the one order every picker lists them in. Sorted here
/// rather than in `build`, since an endpoint that offers hundreds is sorted
/// again on every keystroke that rebuilds a settings page.
final sortedModelsProvider = FutureProvider<List<ModelOption>>((ref) async {
  String name(ModelOption m) => (m.label ?? m.modelId).toLowerCase();
  final models = [...await ref.watch(availableModelsProvider.future)];
  return models..sort((a, b) => name(a).compareTo(name(b)));
});

/// An attachment's bytes: the sync cache for a mirrored image, `resources/`
/// for a local one. Auto-disposed — held, a scrolled-past image would keep
/// its megabytes for the whole session; the mirror cache outlives it either
/// way, so re-showing one costs no second fetch.
final attachmentBytesProvider =
    FutureProvider.autoDispose.family<Uint8List?, ({String chatId, String resource})>(
        (ref, key) async {
  if (ref.watch(isMirroredChatProvider(key.chatId))) {
    return ref.watch(syncHubProvider).resourceBytes(key.chatId, key.resource);
  }
  return ref.watch(chatRepositoryProvider).readResource(key.chatId, key.resource);
});

/// The composer's `/` and `@` menus, read straight off the project's library:
/// Entoli owns its commands and agents, so nothing has to be asked what it
/// knows. The library is per project — `null` is the default, the way it is
/// everywhere a project is named — so a menu offers what the project it is in
/// offers, including an override the project ships.
///
/// A paired device's project offers that device's: auto-disposed, so the
/// follow it holds goes with the menu.
final completionsProvider = Provider.autoDispose
    .family<List<CompletionOption>, ({ProjectRef project, CompletionKind kind})>(
        (ref, spec) => ref.watch(promptLibraryOf(spec.project)).options(spec.kind));

/// An agent's profile picture, or null where none is set. Named like the
/// `.md` — `<agents dir>/<name>.png` — and resolved over the same tier walk
/// the library answers mentions with, so a project's own picture wins over
/// an inherited one. Auto-disposed like [attachmentBytesProvider]: held, an
/// avatar on every row would keep every agent's file in memory. A page that
/// changes one — the agents settings paths do — invalidates the family, an
/// inherited picture being every project's to re-read after a default edit.
final agentPictureProvider =
    FutureProvider.autoDispose.family<Uint8List?, ({String? project, String name})>(
        (ref, key) async {
  final config = ref.watch(appConfigProvider);
  return readAgentPicture(
    config,
    key.name,
    promptTiers(project: key.project, config: config),
  );
});

/// Take the picture a write touched back down. A global write (null
/// [project]) lands in the default project's directory that every project
/// inherits pictures from, so the whole family goes; a project's is read
/// there and nowhere else. The agents settings paths and a marketplace
/// agent install both call it.
void invalidateAgentPicture(WidgetRef ref, String name, {String? project}) {
  if (project == null) {
    ref.invalidate(agentPictureProvider);
  } else {
    ref.invalidate(agentPictureProvider((project: project, name: name)));
  }
}

/// A project's own settings, loaded off `project.json`. Null is the default
/// project, which lives in the data directory. The project name is the
/// constructor argument, the way [ChatController] takes a chat id.
final projectSettingsProvider =
    NotifierProvider.family<ProjectSettingsNotifier, ProjectSettings, String?>(
        ProjectSettingsNotifier.new);

/// A paired device's project's settings, written there. Until it answers,
/// the defaults; a page waits on [projectLoadedProvider] rather than draw them.
final remoteProjectSettingsProvider = NotifierProvider.autoDispose
    .family<ProjectSettingsNotifier, ProjectSettings, ProjectRef>(
        RemoteProjectSettingsNotifier.new);

/// [project]'s settings, on whichever device it is: what a page that shows a
/// project of either watches, and writes through.
NotifierProvider<ProjectSettingsNotifier, ProjectSettings> projectSettingsOf(
        ProjectRef project) =>
    project.device == null
        ? projectSettingsProvider(project.project)
        : remoteProjectSettingsProvider(project);

/// The app settings [project] inherits from: its own device's.
ProviderListenable<AppSettings> appSettingsOf(ProjectRef project) => project.device == null
    ? appSettingsProvider
    : remoteProjectProvider(project).select((p) => p?.app ?? AppSettings());

/// [project]'s skills and agents, on whichever device it is.
ProviderListenable<PromptLibrary> promptLibraryOf(ProjectRef project) =>
    project.device == null
        ? promptLibraryProvider(project.project)
        : remoteProjectProvider(project).select((p) => p?.library ?? PromptLibrary.empty);

/// [project]'s memories, on whichever device it is. A paired device's are
/// asked for on every read.
final memoriesProvider = Provider.family<Memories, ProjectRef>((ref, project) {
  if (project.device != null) return RemoteMemories(ref.watch(syncHubProvider), project);
  final config = ref.watch(appConfigProvider);
  return MemoryStore(config.fs, config.memoryDir(project: project.project));
});

/// Whether Omada runs in [project]: the one rule [omadaFor] resolves — a
/// built-in's spec, a user project's toggle, the default project false —
/// read the way the UI reads it, so a toggle landing re-renders each of
/// these surfaces.
final omadaOnProvider = Provider.family<bool, String?>((ref, project) {
  final spec = builtinProjectOf(project);
  if (spec != null) return spec.omada;
  if (project == null) return false;
  return ref.watch(projectSettingsProvider(project).select((s) => s.omada));
});

/// What the new-chat screen asks over [project]'s badge: the project's own
/// description where it set one, a built-in's shipped question, or the
/// app-wide default — or nothing, where the project set an empty one. The
/// read the screen makes, so an edit landing re-sweeps the headline. Null
/// and empty mean the same thing here — nothing to ask — so the answer is
/// the one string the sweep takes.
final emptyChatQuestionProvider =
    Provider.family<String, String?>((ref, project) {
  final description = project == null
      ? null
      : ref.watch(projectSettingsProvider(project).select((s) => s.description));
  return emptyChatQuestionFor(project, description: description) ?? "";
});

class ProjectSettingsNotifier extends Notifier<ProjectSettings> {
  ProjectSettingsNotifier(this.project);

  final String? project;
  late AppConfig _config;

  @override
  ProjectSettings build() {
    _config = ref.watch(appConfigProvider);
    return ProjectSettings.load(_config, project: project);
  }

  /// Which auto-memory store this project's chats use.
  Future<void> setMemory(Tristate value) => _update((s) => s.memory = value);

  /// Whether this project's chats can carry several agents in one round.
  Future<void> setOmada(bool value) => _update((s) => s.omada = value);

  /// The project's default for how its rounds run. Null is sequential.
  Future<void> setOmadaOrdering(OmadaOrdering? value) =>
      _update((s) => s.omadaOrdering = value);

  /// How many handoff generations a round may run here. Null means the app
  /// default stands.
  Future<void> setOmadaMaxGenerations(int? value) =>
      _update((s) => s.omadaMaxGenerations = value);

  /// How many model calls a direct turn may make here. Null means the app
  /// default stands.
  Future<void> setTurnMaxSteps(int? value) =>
      _update((s) => s.turnMaxSteps = value);

  /// How this project's turns are worded, and whether they number the web
  /// pages they used. Null means the app default stands. One write: the
  /// profile page saves both at once, and two writes of the one
  /// `project.json` would supersede each other.
  Future<void> setReplyStyle({Tone? tone, bool? citations}) => _update((s) => s
    ..tone = tone
    ..citations = citations);

  /// The project's own command variables. Null means none, and the app-level
  /// ones stand alone.
  Future<void> setEnvironment(Map<String, String>? environment) =>
      _update((s) => s.environment = environment);

  /// The project's standing permission rules, saved whole.
  Future<void> setProjectPermissions(List<PermissionRule> value) =>
      _update((s) => s.permissions = value);

  /// The machine directories this project's commands may write to, beside
  /// the workspace the sandbox grants.
  Future<void> setWritableDirs(List<String> value) =>
      _update((s) => s.writableDirs = value);

  /// Whether a sandbox-denied write is offered back as an approval. Null
  /// inherits the app default.
  Future<void> setProjectSandboxReprompt(bool? value) =>
      _update((s) => s.sandboxReprompt = value);

  /// What the new-chat screen asks over this project's badge. Null is the
  /// app default; empty is the screen asking nothing.
  Future<void> setDescription(String? value) =>
      _update((s) => s.description = value);

  /// Override the app-level temporary-chat TTL for this project. Null means
  /// inherit the app default. Re-anchors the project's chats to now so the
  /// badges appear immediately.
  Future<void> setTempChatTtl(TempChatTtl? ttl) async {
    await _update((s) => s.tempChatTtl = ttl);
    await ref.read(chatRepositoryProvider).reanchorProjectTtl(project);
    ref.invalidate(chatListProvider);
  }

  /// The whole of it at once, as a paired device sends it. A TTL change
  /// re-anchors the way [setTempChatTtl] does.
  Future<void> replace(ProjectSettings next) async {
    final ttlChanged = next.tempChatTtl != state.tempChatTtl;
    state = next.copy();
    await state.save(_config, project: project);
    if (ttlChanged) {
      await ref.read(chatRepositoryProvider).reanchorProjectTtl(project);
      ref.invalidate(chatListProvider);
    }
  }

  Future<void> _update(void Function(ProjectSettings) change) async {
    final next = state.copy();
    change(next);
    state = next;
    await next.save(_config, project: project);
  }
}

/// The same setters over a paired device's project: each change is sent there
/// and lands back as what the device wrote.
class RemoteProjectSettingsNotifier extends ProjectSettingsNotifier {
  RemoteProjectSettingsNotifier(this.at) : super(at.project);

  final ProjectRef at;

  @override
  ProjectSettings build() =>
      ref.watch(remoteProjectProvider(at))?.settings.copy() ?? ProjectSettings();

  // The home device re-anchors its own chats.
  @override
  Future<void> setTempChatTtl(TempChatTtl? ttl) => _update((s) => s.tempChatTtl = ttl);

  @override
  Future<void> _update(void Function(ProjectSettings) change) async {
    final next = state.copy();
    change(next);
    state = next;
    // Refused or unanswered: back to what the device last said.
    if (!await ref.read(syncHubProvider).writeRemoteProject(at, next) && ref.mounted) {
      state = ref.read(remoteProjectProvider(at))?.settings.copy() ?? state;
    }
  }
}

/// The one adapter the tools' registry rides over: the provider notifier,
/// so a registration lands in the list this process watches and is armed by
/// the manager's own reload.
class ProviderTriggerOwner implements TriggerRegistryOwner {
  ProviderTriggerOwner(this._container);

  final ProviderContainer _container;

  Triggers get _notifier => _container.read(triggersProvider.notifier);

  @override
  Future<List<Trigger>> triggers() async => _notifier.triggers;

  @override
  Future<Trigger> registerFor(String chatId,
          {required TriggerSource source, required String prompt, String? name, String? member}) async =>
      _notifier.registerFor(chatId, source: source, prompt: prompt, name: name, member: member);

  @override
  PromptLibrary libraryFor(String? project) =>
      // The chat-scoped registry checked its member against this; the
      // project's own library is what every mention resolves against.
      _container.read(promptLibraryProvider(project));

  @override
  Future<void> remove(String id) async => _notifier.remove(id);

  /// What the backend holds: one chat's face over this owner.
  TriggerRegistry registryFor(String chatId, String? project) =>
      ChatTriggerRegistry(this, chatId, project);
}
