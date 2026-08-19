import "dart:typed_data";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../core/config.dart";
import "domain/app_icon.dart";
import "domain/agent_backend.dart";
import "domain/attachment_picker.dart";
import "domain/backup_handoff.dart";
import "domain/background_work.dart";
import "domain/app_restart.dart";
import "domain/app_settings.dart";
import "domain/app_theme.dart";
import "domain/chat_repository.dart";
import "domain/chat_store.dart";
import "domain/file_handoff.dart";
import "domain/link_opener.dart";
import "domain/llm_provider.dart";
import "domain/models.dart";
import "domain/permission.dart";
import "domain/profile.dart";
import "domain/project_settings.dart";
import "domain/prompt_library.dart";
import "domain/temp_chat_ttl.dart";
import "domain/turn_keep_alive.dart";
import "domain/voice.dart";
import "domain/voice_model.dart";
import "domain/voice_model_store.dart";
import "ui/widgets/provider_model_selector.dart";

final chatStoreProvider = Provider<ChatStore>((ref) => throw UnimplementedError());
final agentBackendProvider = Provider<AgentBackend>((ref) => throw UnimplementedError());
final appConfigProvider = Provider<AppConfig>((ref) => throw UnimplementedError());
final attachmentPickerProvider = Provider<AttachmentPicker>((ref) => throw UnimplementedError());
final fileHandoffProvider = Provider<FileHandoff>((ref) => throw UnimplementedError());
final backupHandoffProvider = Provider<BackupHandoff>((ref) => throw UnimplementedError());
final appRestartProvider = Provider<AppRestart>((ref) => throw UnimplementedError());
final voiceProvider = Provider<Voice>((ref) => throw UnimplementedError());
final voiceModelStoreProvider =
    Provider<VoiceModelStore>((ref) => throw UnimplementedError());

/// Which catalog models are on disk. Read once before the app is built and
/// kept in step after that by whatever installs or deletes one — the bargain
/// [promptLibraryProvider] makes, for the reason it makes it. Asked lazily
/// this is a disk scan, and until it answered every reader would be told
/// "none": a button drawn from it would be drawn wrong for those frames, and a
/// button's callback, which reads rather than watches, would be wrong on the
/// first press however long the app had been open.
class InstalledVoiceModels extends Notifier<Set<String>> {
  InstalledVoiceModels(this._seed);

  final Set<String> _seed;

  @override
  Set<String> build() => _seed;

  /// Read the store again. Whatever installs or deletes a model calls this,
  /// which is the only thing that changes the answer.
  Future<void> refresh() async {
    final installed = await ref.read(voiceModelStoreProvider).installed();
    if (ref.mounted) state = installed;
  }
}

final installedVoiceModelsProvider =
    NotifierProvider<InstalledVoiceModels, Set<String>>(
        () => InstalledVoiceModels(const {}));

/// Whether a message can be read out: a platform that can speak, and a speech
/// model picked and installed. Half of [voiceReadyProvider], because reading a
/// message out needs nothing to hear with.
final speechReadyProvider = Provider<bool>((ref) {
  if (!ref.watch(voiceProvider).available) return false;
  final settings = ref.watch(appSettingsProvider);
  // `contains` takes an `Object?`, so a setting naming nothing is simply not
  // in the set.
  return ref
      .watch(installedVoiceModelsProvider)
      .contains(voiceModelOf<SpeechModel>(settings.voiceSpeechModelId)?.id);
});

/// Whether the composer draws its voice button: a platform that can listen, and
/// two models picked and installed. Anything less and pressing it could only
/// lead to an apology.
final voiceReadyProvider = Provider<bool>((ref) {
  if (!ref.watch(speechReadyProvider)) return false;
  final settings = ref.watch(appSettingsProvider);
  return ref
      .watch(installedVoiceModelsProvider)
      .contains(voiceModelOf<RecognitionModel>(settings.voiceRecognitionModelId)?.id);
});

/// Loaded once, before the app is built, because assets are read
/// asynchronously and nothing downstream should have to wait on that.
final promptLibraryProvider = Provider<PromptLibrary>((ref) => PromptLibrary.empty);

class AppSettingsNotifier extends Notifier<AppSettings> {
  late final AppConfig _config;

  @override
  AppSettings build() {
    _config = ref.watch(appConfigProvider);
    return AppSettings.load(_config);
  }

  /// The app-level default, stored exactly as shown: a pair, one half, or
  /// nothing at all.
  Future<void> setDefault(ModelChoice choice) => _update((s) => s
    ..defaultProviderId = choice.providerId
    ..defaultModelId = choice.providerId == null ? null : choice.modelId);

  /// What names a new chat, or nothing at all. Stored as it comes: the field
  /// offers a whole model or none, never half of one.
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
    ..classifierModelId = choice.providerId == null ? null : choice.modelId);

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

  Future<void> setVoiceRecognitionModel(String? id) =>
      _update((s) => s.voiceRecognitionModelId = id);

  /// Picking a different voice resets which of its speakers is used: speaker 40
  /// of Kokoro is nobody in a model with eight.
  Future<void> setVoiceSpeechModel(String? id) => _update((s) => s
    ..voiceSpeechModelId = id
    ..voiceSpeaker = 0);

  Future<void> setVoiceSpeaker(int speaker) =>
      _update((s) => s.voiceSpeaker = speaker);

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
