import "dart:typed_data";

import "package:flutter_riverpod/flutter_riverpod.dart";

import "../core/config.dart";
import "domain/agent_backend.dart";
import "domain/attachment_picker.dart";
import "domain/app_settings.dart";
import "domain/chat_repository.dart";
import "domain/chat_store.dart";
import "domain/models.dart";
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
  Future<void> setDefault(ModelChoice choice) async {
    state = AppSettings(
      defaultProviderId: choice.providerId,
      defaultModelId: choice.providerId == null ? null : choice.modelId,
      opencodeEnv: state.opencodeEnv,
    );
    await state.save(_config);
  }

  /// Takes effect on the next server a chat starts; one already running keeps
  /// the environment it was spawned with.
  Future<void> setOpencodeEnv(Map<String, String> env) async {
    state = AppSettings(
      defaultProviderId: state.defaultProviderId,
      defaultModelId: state.defaultModelId,
      opencodeEnv: Map.unmodifiable(env),
    );
    await state.save(_config);
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

/// How long a turn may go without progress before we give up on it. opencode
/// retries a rate limit internally for over a minute before reporting it; this
/// keeps the wait ours to decide. Reset by real output, not by retry notices.
final turnStallTimeoutProvider = Provider<Duration>((ref) => const Duration(seconds: 45));

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
