import "../../../core/config.dart";
import "../../../data/miniswe/llm/llm_registry.dart";
import "../../../data/miniswe/miniswe_backend.dart";
import "../../../domain/agent_backend.dart";
import "../../../domain/app_settings.dart";
import "../../../domain/chat_store.dart";
import "../../../domain/prompt_library.dart";
import "../../../domain/shell.dart";

/// The browser has no opencode to spawn and no shell to run commands in, so
/// mini-swe-agent is the only backend and it reaches the model but not the
/// machine. A command comes back saying so rather than failing the turn.
AgentBackend createBackend(AppConfig config, PromptLibrary library, ChatStore store) {
  AppSettings settings() => AppSettings.load(config);
  return MinisweBackend(
    config: config,
    library: library,
    shell: const UnavailableShell(),
    registry: LlmRegistry(
      providers: () => settings().llmProviders,
      lookupEnv: (name) => settings().opencodeEnv[name],
    ),
  );
}
