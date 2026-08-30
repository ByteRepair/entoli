import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../core/config.dart";
import "../core/platform/platform.dart" show createPromptSources;
import "data/builtin/builtin_backend.dart";
import "data/local/file_reminder_store.dart";
import "domain/app_icon.dart";
import "domain/agent_backend.dart";
import "domain/app_restart.dart";
import "domain/app_settings.dart";
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
import "domain/permission.dart";
import "domain/profile.dart";
import "domain/project_settings.dart";
import "domain/prompt_library.dart";
import "domain/reminder.dart";
import "domain/reminder_alarms.dart";
import "domain/reminder_runner.dart";
import "domain/reminder_scheduler.dart";
import "domain/rootfs_store.dart";
import "domain/shell.dart";
import "data/sync/sync_hub.dart";
import "domain/temp_chat_ttl.dart";
import "domain/theme_colour.dart";
import "domain/turn_keep_alive.dart";
import "domain/voice.dart";
import "domain/voice_model.dart"
    show nativeRecognition, nativeSpeech, RecognitionModel, SpeechModel, voiceModelOf;
import "domain/voice_model_store.dart";

final chatStoreProvider = Provider<ChatStore>((ref) => throw UnimplementedError());
final agentBackendProvider = Provider<AgentBackend>((ref) => throw UnimplementedError());
final shellProvider = Provider<Shell>((ref) => throw UnimplementedError());

/// Where the shell for [workspace] is standing, live: what the composer's bar
/// draws while a `!` command is being typed. Null where there is no workspace
/// to ask about, or the shell holds no session for one — which the caller falls
/// back to the workspace itself for.
final chatShellCwdProvider =
    Provider.family<ValueListenable<String?>?, String?>((ref, workspace) {
  if (workspace == null) return null;
  return ref.watch(shellProvider).sessionCwd(workspace);
});
final appConfigProvider = Provider<AppConfig>((ref) => throw UnimplementedError());
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
class InstalledVoiceModels extends Notifier<Set<String>> {
  InstalledVoiceModels(this._seed, {this.system = const {}});

  final Set<String> _seed;

  /// The sentinels this device can honour. Held rather than folded into the
  /// seed, because a re-scan reads the store and would otherwise drop them.
  final Set<String> system;

  @override
  Set<String> build() => _seed;

  /// Read the store again. Whatever installs or deletes a model calls this,
  /// which is the only thing that changes the answer.
  Future<void> refresh() async {
    final installed = await ref.read(voiceModelStoreProvider).installed();
    if (ref.mounted) state = {...installed, ...system};
  }
}

final installedVoiceModelsProvider =
    NotifierProvider<InstalledVoiceModels, Set<String>>(
        () => InstalledVoiceModels(const {}));

final rootfsStoreProvider = Provider<RootfsStore>((ref) => throw UnimplementedError());

/// Which distributions are installed and whole. Seeded before the app is built
/// and refreshed by whatever installs or deletes one, for the reason
/// [InstalledVoiceModels] is: the Terminal page's rows are drawn from it, and a
/// lazy scan would draw every one of them as "not installed" first.
class InstalledRootfs extends Notifier<Set<String>> {
  InstalledRootfs(this._seed);

  final Set<String> _seed;

  @override
  Set<String> build() => _seed;

  Future<void> refresh() async {
    final installed = await ref.read(rootfsStoreProvider).installed();
    if (ref.mounted) state = installed;
  }
}

final installedRootfsProvider =
    NotifierProvider<InstalledRootfs, Set<String>>(() => InstalledRootfs(const {}));

/// The Byte Repair tooling store, overridden in `main` with one that knows the
/// cache directory. Throws until then, the way `rootfsStoreProvider` does.
final byteRepairStoreProvider =
    Provider<ByteRepairStore>((ref) => throw UnimplementedError());

/// The version of each tool the setup installs (ESBMC, make, gh), or null
/// where one is not installed. Refreshed by the settings page after a setup run.
final byteRepairToolVersionsProvider =
    FutureProvider<Map<String, String?>>((ref) async {
  final store = ref.watch(byteRepairStoreProvider);
  final shell = ref.watch(shellProvider);
  return store.runToolVersions(shell);
});

/// Whether a project requiring setup has been set up. True for projects that
/// don't require setup (the common case); for one that does, checks the
/// `.setup-complete` marker in the project's directory. Invalidated by the
/// settings page after Run Setup or Delete.
final setupCompleteProvider =
    Provider.family<bool, String?>((ref, project) {
  final spec = builtinProjectOf(project);
  if (spec?.requiresSetup != true) return true;
  final config = ref.watch(appConfigProvider);
  return File(config.setupCompleteFile(project: project)).existsSync();
});

final localModelStoreProvider =
    Provider<LocalModelStore>((ref) => const UnavailableLocalModelStore());

/// The server that answers from this device, and nothing where no build of one
/// reached it. Overridden in `main`, since resolving the binary is a channel
/// round trip and every reader of this is synchronous.
final localLlmProvider = Provider<LocalLlm>((ref) => const UnavailableLocalLlm());

/// Which models are downloaded and whole. Seeded before the app is built and
/// refreshed by whatever installs or deletes one, for the reason
/// [InstalledRootfs] is: the rows are drawn from it, and a lazy scan would draw
/// every one of them as "not installed" first.
class InstalledLocalModels extends Notifier<Set<String>> {
  InstalledLocalModels(this._seed);

  final Set<String> _seed;

  @override
  Set<String> build() => _seed;

  Future<void> refresh() async {
    final installed = await ref.read(localModelStoreProvider).installed();
    if (ref.mounted) state = installed;
  }
}

final installedLocalModelsProvider =
    NotifierProvider<InstalledLocalModels, Set<String>>(
        () => InstalledLocalModels(const {}));

/// What is loaded on the device and how far each one has got. A notifier over
/// the port's own [ValueListenable] rather than a second copy of the state:
/// what starts a model is a turn asking for one, so the settings page is
/// watching something it did not start.
class LocalLlmStatus extends Notifier<List<LocalLlmState>> {
  @override
  List<LocalLlmState> build() {
    final llm = ref.watch(localLlmProvider);
    void update() => state = llm.running.value;
    llm.running.addListener(update);
    ref.onDispose(() => llm.running.removeListener(update));
    return llm.running.value;
  }
}

final localLlmStateProvider =
    NotifierProvider<LocalLlmStatus, List<LocalLlmState>>(LocalLlmStatus.new);

/// The most cores worth offering the cores slider, or null where there is no
/// server. Read off the port so the web UI needs no `dart:io` to know the
/// machine's core count.
final localMaxThreadsProvider =
    Provider<int?>((ref) => ref.watch(localLlmProvider).maxThreads);

/// The on-device prompt warm-up, or null where there is no server to warm
/// against — every platform but Android, and an Android whose build shipped no
/// model server. Overridden in `main`, where the shell that words the system
/// prompt and the foreground service that shows its notification both are.
final localPrefillProvider = Provider<LocalPrefill?>((ref) => null);

/// What the warm-up is doing, for the settings page to draw. A notifier over
/// the port's own [ValueListenable], like [localLlmStateProvider] beside it.
class LocalPrefillStatus extends Notifier<LocalPrefillState?> {
  @override
  LocalPrefillState? build() {
    final prefill = ref.watch(localPrefillProvider);
    if (prefill == null) return null;
    void update() => state = prefill.state.value;
    prefill.state.addListener(update);
    ref.onDispose(() => prefill.state.removeListener(update));
    return prefill.state.value;
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

/// Loaded once, before the app is built, because assets are read
/// asynchronously and nothing downstream should have to wait on that.
/// The prompt library, built once at startup and rebuilt only where something
/// on screen says the disk changed — the Skills page, importing or deleting
/// one. See "Skills and agents" in `lib/domain/CLAUDE.md` for why it is
/// otherwise read once: nothing downstream waits on it, and a file added
/// behind the app's back reaches the next launch.
class PromptLibraryNotifier extends Notifier<PromptLibrary> {
  PromptLibraryNotifier([PromptLibrary? initial]) : _initial = initial;

  final PromptLibrary? _initial;

  @override
  PromptLibrary build() => _initial ?? PromptLibrary.empty;

  /// Read the sources again, and hand the backend its copy: the agent holds
  /// one of its own for the `task` tool and the skills it offers a turn.
  Future<void> reload() async {
    final next =
        await PromptLibrary.from(createPromptSources(ref.read(appConfigProvider)));
    state = next;
    final backend = ref.read(agentBackendProvider);
    if (backend is BuiltinBackend) backend.library = next;
  }
}

final promptLibraryProvider = NotifierProvider<PromptLibraryNotifier, PromptLibrary>(
    PromptLibraryNotifier.new);

class AppSettingsNotifier extends Notifier<AppSettings> {
  late final AppConfig _config;

  @override
  AppSettings build() {
    _config = ref.watch(appConfigProvider);
    final loaded = AppSettings.load(_config);
    // The device's own engines are the default where it has them — voice mode
    // works the moment the app is installed, with nothing to download. Each
    // side is defaulted on its own, so a phone with a synthesiser and no
    // recognition service gets the half it can do and leaves the other
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
    if (system.isEmpty) return loaded;
    final defaulted = loaded.copy();
    if (system.contains(nativeRecognition.id)) {
      defaulted.voiceRecognitionModelId ??= nativeRecognition.id;
    }
    if (system.contains(nativeSpeech.id)) {
      defaulted.voiceSpeechModelId ??= nativeSpeech.id;
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

  /// Read when a command runs, so an edit reaches the next one.
  Future<void> setEnvironment(Map<String, String> env) =>
      _update((s) => s.environment = Map.unmodifiable(env));

  Future<void> setApproveMode(ApproveMode value) =>
      _update((s) => s.approveMode = value);

  /// What classifies commands when auto mode is on, or nothing at all.
  Future<void> setClassifierModel(ModelChoice choice) => _update((s) => s
    ..classifierProviderId = choice.providerId
    ..classifierModelId = choice.modelId);

  /// Whether `@path` references inside an AGENTS.md pull in more files. The
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

  /// The user's profile, injected into the system prompt. Null clears it.
  Future<void> setProfile(Profile? profile) =>
      _update((s) => s.profile = profile);

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

  Future<void> setTurnUrl(String? url) => _update((s) => s.turnUrl = url);

  Future<void> setTurnCredentials(String? username, String? password) =>
      _update((s) => s
        ..turnUsername = username
        ..turnPassword = password);

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

  /// The endpoints the agent can call. The model list is rebuilt from them, so
  /// it is invalidated here rather than left showing the old one.
  Future<void> setProviders(List<LlmProviderConfig> providers) async {
    await _update((s) => s.llmProviders = List.unmodifiable(providers));
    ref.invalidate(availableModelsProvider);
  }

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

final backgroundWorkProvider =
    Provider<BackgroundWork>((ref) => throw UnimplementedError());

final syncHubProvider = Provider<SyncHub>((ref) => throw UnimplementedError());

/// One of the hub's `ValueNotifier`s, watchable. Riverpod has nothing that
/// watches a listenable, so a listener bridges it; the subclasses below name
/// which notifier and nothing else, which is also what lets a test override
/// one without a hub to read.
abstract class HubValue<T> extends Notifier<T> {
  ValueListenable<T> of(SyncHub hub);

  @override
  T build() {
    final source = of(ref.watch(syncHubProvider));
    void changed() => state = source.value;
    source.addListener(changed);
    ref.onDispose(() => source.removeListener(changed));
    return source.value;
  }
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

/// The other direction: chats of *this* device a paired one is driving, by
/// the name of the device driving them.
class DrivenChats extends HubValue<Map<String, String>> {
  @override
  ValueListenable<Map<String, String>> of(SyncHub hub) => hub.drivenChats;
}

final drivenChatsProvider =
    NotifierProvider<DrivenChats, Map<String, String>>(DrivenChats.new);

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

final isMirroredChatProvider = Provider.family<bool, String>((ref, chatId) {
  return ref
      .watch(remoteChatsProvider.select((chats) => chats.any((c) => c.chatId == chatId)));
});

/// Read once in `main` for its effect: it listens to the backend from the
/// moment it exists, and nothing ever asks it anything. Here rather than a bare
/// object in `main` so that its lifetime is the container's and `dispose` has a
/// caller.
/// The single owner of the platform's download slot — see [DownloadHold]. Every
/// catalog's notifier reports through it rather than to [BackgroundWork].
final downloadHoldProvider =
    Provider<DownloadHold>((ref) => DownloadHold(ref.watch(backgroundWorkProvider)));

final turnKeepAliveProvider = Provider<TurnKeepAlive>((ref) {
  final keepAlive = TurnKeepAlive(
      ref.watch(agentBackendProvider), ref.watch(backgroundWorkProvider));
  ref.onDispose(keepAlive.dispose);
  return keepAlive;
});

final reminderAlarmsProvider =
    Provider<ReminderAlarms>((ref) => const UnavailableReminderAlarms());

/// The user's reminders, seeded from disk before the container exists and
/// written through on every change — the same bargain [InstalledRootfs] makes.
class Reminders extends Notifier<List<Reminder>> implements ReminderList {
  Reminders(this._seed);

  final List<Reminder> _seed;
  late FileReminderStore _store;

  @override
  List<Reminder> build() {
    _store = FileReminderStore(ref.watch(appConfigProvider));
    return _seed;
  }

  @override
  List<Reminder> get reminders => state;

  @override
  Future<void> write(List<Reminder> reminders) async {
    state = reminders;
    await _store.save(reminders);
  }

  @override
  Future<void> replace(Reminder reminder) => write([
        for (final r in state) if (r.id == reminder.id) reminder else r,
      ]);

  /// Add with its alarm request code assigned: the one place codes are handed
  /// out, so they stay unique for the reminder's life.
  Future<void> add(Reminder reminder) => write([
        ...state,
        reminder.copyWith(requestCode: nextRequestCode(state)),
      ]);

  Future<void> remove(String id) =>
      write([for (final r in state) if (r.id != id) r]);

  Future<void> setEnabled(String id, bool enabled) async {
    final at = state.indexWhere((r) => r.id == id);
    if (at < 0) return;
    final reminder = state[at];
    final next = enabled ? reminder.nextOccurrence(DateTime.now()) : null;
    // Disabling disarms it; re-enabling re-aims at the next occurrence.
    await replace(reminder.copyWith(enabled: enabled, clearNextFireAt: true)
        .copyWith(nextFireAt: next));
  }
}

final remindersProvider =
    NotifierProvider<Reminders, List<Reminder>>(() => Reminders(const []));

final reminderTurnDriverProvider =
    Provider<ReminderTurnDriver>((ref) => throw UnimplementedError());

final reminderRunnerProvider = Provider<ReminderRunner>((ref) {
  return ReminderRunner(
    repo: ref.watch(chatRepositoryProvider),
    driver: ref.watch(reminderTurnDriverProvider),
    onListChanged: (_) => ref.invalidate(chatListProvider),
    onReminderFired: (reminder) =>
        ref.read(remindersProvider.notifier).replace(reminder),
  );
});

/// Started once beside the sweep timer. It listens to the list from here, so
/// an edit anywhere re-arms the timer and re-syncs the alarms without the
/// editor having to know the scheduler exists.
final reminderSchedulerProvider = Provider<ReminderScheduler>((ref) {
  final scheduler = ReminderScheduler(
    alarms: ref.watch(reminderAlarmsProvider),
    runner: ref.watch(reminderRunnerProvider),
    list: ref.watch(remindersProvider.notifier),
    projects: () => ref.read(chatRepositoryProvider).listProjects(),
  );
  ref.onDispose(scheduler.dispose);
  ref.listen(remindersProvider, (_, _) {
    unawaited(scheduler.reload());
  });
  return scheduler;
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
    library: ref.watch(promptLibraryProvider),
  );
});

/// The sidebar's list: the chats on disk, in every project — each says which
/// one it is in. A new chat joins when its first message is saved, and whoever
/// changes what the list shows invalidates it.
final chatListProvider = FutureProvider<List<ChatState>>((ref) async {
  final repo = ref.watch(chatRepositoryProvider);
  return repo.listChats();
});

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
final projectListProvider = FutureProvider((ref) async {
  final repo = ref.watch(chatRepositoryProvider);
  return repo.listProjects();
});

final availableModelsProvider = FutureProvider<List<ModelOption>>((ref) async {
  final backend = ref.watch(agentBackendProvider);
  return backend.models();
});

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

/// The composer's `/` and `@` menus, read straight off the library: Entoli
/// owns its commands and agents, so nothing has to be asked what it knows.
final completionsProvider = Provider.family<List<CompletionOption>, CompletionKind>(
    (ref, kind) => ref.watch(promptLibraryProvider).options(kind));

/// A project's own settings, loaded off `project.json`. Null is the default
/// project, which lives in the data directory. The project name is the
/// constructor argument, the way [ChatController] takes a chat id.
final projectSettingsProvider =
    NotifierProvider.family<ProjectSettingsNotifier, ProjectSettings, String?>(
        ProjectSettingsNotifier.new);

class ProjectSettingsNotifier extends Notifier<ProjectSettings> {
  ProjectSettingsNotifier(this.project);

  final String? project;
  late AppConfig _config;

  @override
  ProjectSettings build() {
    _config = ref.watch(appConfigProvider);
    return ProjectSettings.load(_config, project: project);
  }

  /// Whether this project keeps an auto-memory store of its own rather than
  /// sharing the default project's.
  Future<void> setUseProjectMemory(bool value) async {
    final next = state.copy()..useProjectMemory = value;
    state = next;
    await next.save(_config, project: project);
  }

  /// The project's own command variables. Null means none, and the app-level
  /// ones stand alone.
  Future<void> setEnvironment(Map<String, String>? environment) async {
    final next = state.copy()..environment = environment;
    state = next;
    await next.save(_config, project: project);
  }

  /// Override the app-level temporary-chat TTL for this project. Null means
  /// inherit the app default. Re-anchors the project's chats to now so the
  /// badges appear immediately.
  Future<void> setTempChatTtl(TempChatTtl? ttl) async {
    final next = state.copy()..tempChatTtl = ttl;
    state = next;
    await next.save(_config, project: project);
    await ref.read(chatRepositoryProvider).reanchorProjectTtl(project);
    ref.invalidate(chatListProvider);
  }
}
