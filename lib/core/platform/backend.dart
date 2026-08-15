import "../../data/miniswe/llm/llm_registry.dart";
import "../../data/miniswe/miniswe_backend.dart";
import "../../domain/agent_backend.dart";
import "../../domain/app_settings.dart";
import "../../domain/prompt_library.dart";
import "../config.dart";
import "shell.dart";

/// The agent, wired to this platform's shell and to whatever the settings page
/// last wrote. [library] is agent-chat's commands and agents, which the agent
/// expands itself.
///
/// The settings are read when used rather than captured: they are edited while
/// the app runs, and the next turn has to see the edit.
AgentBackend createBackend(AppConfig config, PromptLibrary library) {
  AppSettings settings() => AppSettings.load(config);
  return MinisweBackend(
    config: config,
    library: library,
    shell: platformShell(environment: () => settings().environment),
    registry: LlmRegistry(
      providers: () => settings().llmProviders,
      // Settings wins, but a key already exported is found without having to
      // be pasted in.
      lookupEnv: (name) => settings().environment[name] ?? processEnv(name),
    ),
  );
}
