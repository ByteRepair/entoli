import "dart:typed_data";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../core/config.dart";
import "domain/agent_backend.dart";
import "domain/attachment_picker.dart";
import "domain/app_settings.dart";
import "domain/chat_repository.dart";
import "domain/chat_store.dart";
import "domain/llm_provider.dart";
import "domain/models.dart";
import "domain/permission.dart";
import "domain/prompt_library.dart";
import "ui/widgets/provider_model_selector.dart";

final chatStoreProvider = Provider<ChatStore>((ref) => throw UnimplementedError());
final agentBackendProvider = Provider<AgentBackend>((ref) => throw UnimplementedError());
final appConfigProvider = Provider<AppConfig>((ref) => throw UnimplementedError());
final attachmentPickerProvider = Provider<AttachmentPicker>((ref) => throw UnimplementedError());

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

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  // Deliberately not watching appSettingsProvider: the repository reads the
  // settings when it uses them, so changing a default does not rebuild the
  // repository and re-scan every chat off disk.
  return ChatRepository(
    ref.watch(chatStoreProvider),
    ref.watch(agentBackendProvider),
    () => ref.read(appSettingsProvider),
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

/// The composer's `/` and `@` menus, read straight off the library: agent-chat
/// owns its commands and agents, so nothing has to be asked what it knows.
final completionsProvider = Provider.family<List<CompletionOption>, CompletionKind>(
    (ref, kind) => ref.watch(promptLibraryProvider).options(kind));
