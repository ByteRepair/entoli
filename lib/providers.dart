import "dart:typed_data";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../core/config.dart";
import "core/platform/default_backend.dart";
import "domain/agent_backend.dart";
import "domain/attachment_picker.dart";
import "domain/app_settings.dart";
import "domain/chat_repository.dart";
import "domain/chat_store.dart";
import "domain/llm_provider.dart";
import "domain/models.dart";
import "domain/prompt_library.dart";
import "ui/widgets/provider_model_selector.dart";

/// Which backends this platform can run at all. Android and the web have no
/// opencode binary to spawn, so it is never offered there — a provider rather
/// than a direct call so a test can pretend to be a phone.
final availableBackendsProvider =
    Provider<List<BackendKind>>((ref) => availableBackendKinds());

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

  /// Takes effect on the next server a chat starts; one already running keeps
  /// the environment it was spawned with.
  Future<void> setOpencodeEnv(Map<String, String> env) =>
      _update((s) => s.opencodeEnv = Map.unmodifiable(env));

  /// Which runtime a new chat gets. Null puts it back on the platform's own
  /// default, which is what the picker shows as `Default`.
  Future<void> setDefaultBackend(BackendKind? kind) =>
      _update((s) => s.defaultBackend = kind);

  Future<void> setApproveCommands(bool value) =>
      _update((s) => s.approveCommands = value);

  /// The endpoints mini-swe-agent can call. The model list is rebuilt from
  /// them, so it is invalidated here rather than left showing the old one.
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

/// Overrides how long a turn may go without progress before we give up on it.
/// Null asks the backend running the chat, which is where the answer belongs —
/// this exists so a test does not have to wait out a real one.
final turnStallTimeoutProvider = Provider<Duration?>((ref) => null);

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

/// The composer's `/` and `@` menus. The same list whichever backend runs the
/// chat: agent-chat owns its commands and agents, and hands them down to
/// whatever is executing the turn.
final completionsProvider = Provider.family<List<CompletionOption>, CompletionKind>(
    (ref, kind) => ref.watch(promptLibraryProvider).options(kind));
