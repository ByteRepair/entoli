import "package:fs_shim/fs.dart";

import "../../data/local/file_chat_store.dart";
import "../../data/miniswe/llm/llm_registry.dart";
import "../../data/miniswe/miniswe_backend.dart";
import "../../data/prompts/prompt_sources.dart";
import "../../domain/agent_backend.dart";
import "../../domain/app_settings.dart";
import "../../domain/chat_store.dart";
import "../../domain/prompt_library.dart";
import "../config.dart";
import "io/platform.dart" if (dart.library.js_interop) "web/platform.dart";

/// What the app is given by the platform it is running on: a shell or none,
/// the network or CORS, a directory on a disk or a database in a page. The
/// conditional import above is the app's only one, so everything
/// platform-varying is resolved here and nothing downstream asks again.
///
/// The filesystem is the thing that stopped varying. Both platforms get a
/// `FileSystem` and the same layout inside it, so the chat store and the
/// prompt sources below are built once rather than per platform.

/// The agent, wired to what this platform can reach and to whatever the
/// settings page last wrote. [library] is Entoli's commands and agents, which
/// the agent expands itself.
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

/// A real filesystem on desktop and Android, IndexedDB in a browser. What
/// [AppConfig] is built on, so it is asked for first.
FileSystem createFileSystem() => platformFileSystem();

/// Where this platform keeps things — the one question a `FileSystem` does not
/// answer for itself.
Future<String> dataDir() => platformDataDir();

/// Ask the platform not to throw away what we wrote. Only a browser has
/// anything to say here.
Future<void> persist() => platformPersist();

ChatStore createChatStore(AppConfig config) => FileChatStore(config);

/// The presets, and the user's own beside them. Their directory is on the
/// config's filesystem, so it exists on every platform now.
List<PromptSource> createPromptSources(AppConfig config) =>
    [const BundledPrompts(), DirectoryPrompts(config)];
