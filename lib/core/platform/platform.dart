import "../../data/miniswe/llm/llm_registry.dart";
import "../../data/miniswe/miniswe_backend.dart";
import "../../domain/agent_backend.dart";
import "../../domain/app_settings.dart";
import "../../domain/chat_store.dart";
import "../../domain/prompt_library.dart";
import "../../domain/storage.dart";
import "../config.dart";
import "io/platform.dart" if (dart.library.js_interop) "web/platform.dart";

/// What the app is given by the platform it is running on: a shell or none,
/// the network or CORS, a filesystem or a page's memory. The conditional
/// import above is the app's only one, so everything platform-varying is
/// resolved here and nothing downstream asks again.

/// The agent, wired to what this platform can reach and to whatever the
/// settings page last wrote. [library] is Entoli's commands and agents, which
/// the agent expands itself.
///
/// The settings are read when used rather than captured: they are edited while
/// the app runs, and the next turn has to see the edit.
AgentBackend createBackend(AppConfig config, PromptLibrary library) {
  AppSettings settings() => AppSettings.load(config);
  return MinisweBackend(
    config: config,
    library: library,
    shell: platformShell(environment: () => settings().environment),
    webSearch: platformWebSearch(),
    registry: LlmRegistry(
      providers: () => settings().llmProviders,
      // Settings wins, but a key already exported is found without having to
      // be pasted in.
      lookupEnv: (name) => settings().environment[name] ?? processEnv(name),
    ),
  );
}

/// The filesystem, or a page's memory standing in for one. What [AppConfig] is
/// built on, so it is asked for first.
Storage createStorage() => platformStorage();

/// Chats on disk, or held for the life of the page where there is no disk.
ChatStore createChatStore(AppConfig config) => platformChatStore(config);

/// The presets, and the user's own beside them where there is a directory to
/// have written one in.
List<PromptSource> createPromptSources(AppConfig config) =>
    platformPromptSources(config);
