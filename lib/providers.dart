import "dart:typed_data";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../core/config.dart";
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
import "domain/chat_repository.dart";
import "domain/chat_store.dart";
import "domain/file_handoff.dart";
import "domain/link_opener.dart";
import "domain/llm_provider.dart";
import "domain/local_llm.dart";
import "domain/local_model_store.dart";
import "domain/models.dart";
import "domain/permission.dart";
import "domain/profile.dart";
import "domain/project_settings.dart";
import "domain/prompt_library.dart";
import "domain/rootfs_store.dart";
import "domain/temp_chat_ttl.dart";
import "domain/turn_keep_alive.dart";
import "domain/voice.dart";
import "domain/voice_model.dart"
    show nativeRecognition, nativeSpeech, RecognitionModel, SpeechModel, voiceModelOf;
import "domain/voice_model_store.dart";

final chatStoreProvider = Provider<ChatStore>((ref) => throw UnimplementedError());
final agentBackendProvider = Provider<AgentBackend>((ref) => throw UnimplementedError());
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

/// How far the on-device server has got. A notifier over the port's own
/// [ValueListenable] rather than a second copy of the state: the server is
/// started from the settings page and from startup, and both have to redraw the
/// same row.
class LocalLlmStatus extends Notifier<LocalLlmState> {
  @override
  LocalLlmState build() {
    final llm = ref.watch(localLlmProvider);
    void update() => state = llm.state.value;
    llm.state.addListener(update);
    ref.onDispose(() => llm.state.removeListener(update));
    return llm.state.value;
  }
}

final localLlmStateProvider =
    NotifierProvider<LocalLlmStatus, LocalLlmState>(LocalLlmStatus.new);

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

/// Loaded once, before the app is built, because assets are read
/// asynchronously and nothing downstream should have to wait on that.
final promptLibraryProvider = Provider<PromptLibrary>((ref) => PromptLibrary.empty);

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

  /// Which Linux the agent's commands run inside, or null for Android itself.
  /// It reaches the next command rather than the next turn: the shell resolves
  /// this per command.
  Future<void> setRootfs(String? id) => _update((s) => s.rootfsId = id);

  /// What is served from this device. Unpicking clears the other two, since
  /// neither means anything without a model and left behind they would be
  /// applied to whatever is picked next.
  Future<void> setLocalModel(String? id) => _applyLocal((s) => s
    ..localModelId = id
    ..localModelDevice = id == null ? null : s.localModelDevice
    ..localModelContext = id == null ? null : s.localModelContext);

  /// Which accelerator it is offloaded to, by the name `--list-devices` gave
  /// it. Null is the CPU.
  Future<void> setLocalDevice(String? device) =>
      _applyLocal((s) => s.localModelDevice = device);

  Future<void> setLocalContext(int? tokens) =>
      _applyLocal((s) => s.localModelContext = tokens);

  /// Stored and then applied, so the pick survives the server failing to
  /// honour it and is tried again at the next launch. One field at a time and
  /// never a sibling: threading the other two through every setter is what
  /// lets a value a picker is *showing* as Default be silently written back.
  ///
  /// The model list is rebuilt because a running server is an endpoint: picking
  /// one adds a model to every picker in the app, and unpicking takes it away.
  Future<void> _applyLocal(void Function(AppSettings) change) async {
    await _update(change);
    await applyLocalModel(ref.read(localLlmProvider), state);
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

final linkOpenerProvider =
    Provider<LinkOpener>((ref) => throw UnimplementedError());

final backgroundWorkProvider =
    Provider<BackgroundWork>((ref) => throw UnimplementedError());

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

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  // Deliberately not watching appSettingsProvider: the repository reads the
  // settings when it uses them, so changing a default does not rebuild the
  // repository and re-scan every chat off disk.
  return ChatRepository(
    ref.watch(chatStoreProvider),
    ref.watch(agentBackendProvider),
    () => ref.read(appSettingsProvider),
    ref.watch(appConfigProvider),
  );
});

/// The sidebar's list: the chats on disk, in every project — each says which
/// one it is in. A new chat joins when its first message is saved, and whoever
/// changes what the list shows invalidates it.
final chatListProvider = FutureProvider((ref) async {
  final repo = ref.watch(chatRepositoryProvider);
  return repo.listChats();
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

/// An attachment's bytes, read back from the chat's `resources/`, so a message
/// that has already been sent can still show what it carried. Auto-disposed:
/// held, a scrolled-past image would keep its megabytes for the whole session.
final attachmentBytesProvider =
    FutureProvider.autoDispose.family<Uint8List?, ({String chatId, String resource})>((ref, key) =>
        ref.watch(chatRepositoryProvider).readResource(key.chatId, key.resource));

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

  Future<void> setProfile(Profile? profile) async {
    final next = state.copy()..profile = profile;
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
