import "package:flutter_riverpod/flutter_riverpod.dart";

import "../core/config.dart";
import "domain/agent_backend.dart";
import "domain/app_settings.dart";
import "domain/chat_repository.dart";
import "domain/chat_store.dart";
import "domain/models.dart";

final chatStoreProvider = Provider<ChatStore>((ref) => throw UnimplementedError());
final agentBackendProvider = Provider<AgentBackend>((ref) => throw UnimplementedError());
final appConfigProvider = Provider<AppConfig>((ref) => throw UnimplementedError());

class AppSettingsNotifier extends Notifier<AppSettings> {
  late final AppConfig _config;

  @override
  AppSettings build() {
    _config = ref.watch(appConfigProvider);
    return AppSettings.load(_config);
  }

  Future<void> setDefaultModel(String providerId, String modelId) =>
      _store(AppSettings(defaultProviderId: providerId, defaultModelId: modelId));

  /// Keep a provider without pinning a model, or clear both with null.
  Future<void> setDefaultProvider(String? providerId) =>
      _store(AppSettings(defaultProviderId: providerId));

  Future<void> _store(AppSettings settings) async {
    state = settings;
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
  return backend.listModelsStandalone();
});