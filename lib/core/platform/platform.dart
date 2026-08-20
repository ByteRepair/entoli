import "package:fs_shim/fs.dart";

import "../../data/builtin/builtin_backend.dart";
import "../../data/builtin/llm/llm_registry.dart";
import "../../data/local/file_chat_store.dart";
import "../../data/prompts/prompt_sources.dart";
import "../../domain/agent_backend.dart";
import "../../domain/app_settings.dart";
import "../../domain/assistant_launch.dart";
import "../../domain/backup_handoff.dart";
import "../../domain/chat_store.dart";
import "../../domain/file_handoff.dart";
import "../../domain/prompt_library.dart";
import "../../domain/rootfs_store.dart";
import "../../domain/shell.dart";
import "../../domain/voice.dart";
import "../../domain/voice_model_store.dart";
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
/// the agent expands itself. [store] is the chat store, which the agent needs
/// to write artifacts to the chat's `artifacts/` dir.
AgentBackend createBackend(
  AppConfig config,
  PromptLibrary library,
  ChatStore store, {
  Toolset? tools,
  RootfsStore? rootfs,
  String? abi,
}) {
  AppSettings settings() => AppSettings.load(config);
  return BuiltinBackend(
    config: config,
    library: library,
    shell: platformShell(
      environment: () => settings().environment,
      tools: tools,
      // Resolved per command rather than once: a Linux installed from the
      // settings page reaches the next command, and one deleted stops being
      // where commands run without the app having to be restarted.
      sandbox: () => platformSandbox(
        dataDir: config.dataDir,
        proot: tools?.proot,
        store: rootfs,
        rootfsId: settings().rootfsId,
        abi: abi,
      ),
    ),
    webSearch: platformWebSearch(),
    store: store,
    registry: LlmRegistry(
      providers: () => settings().llmProviders,
      // Settings wins, but a key already exported is found without having to
      // be pasted in.
      lookupEnv: (name) => settings().environment[name] ?? processEnv(name),
    ),
  );
}

/// Lay out the tools this build ships for the device, and answer with what
/// finds them. Null everywhere but Android. Called before the backend is
/// built, since the shell is handed the result once.
Future<Toolset?> installBundledTools(String cacheDir) =>
    platformInstallTools(cacheDir);

/// Where a downloaded Linux is kept, and which architecture to fetch one for.
/// Two calls rather than one because the settings page manages what is
/// installed with nothing listening, while the shell needs the store to find
/// what it has been told to run in — the arrangement the voice models already
/// have.
RootfsStore createRootfsStore(String cacheDir) => platformRootfsStore(cacheDir);

Future<String?> deviceAbi() => platformAbi();

/// A real filesystem on desktop and Android, IndexedDB in a browser. What
/// [AppConfig] is built on, so it is asked for first.
FileSystem createFileSystem() => platformFileSystem();

/// Where this platform keeps things — the one question a `FileSystem` does not
/// answer for itself.
Future<String> dataDir() => platformDataDir();

/// Where things that can be fetched again go, which is deliberately *not*
/// under [dataDir] — see `domain/voice_model_store.dart` for what that buys.
Future<String> cacheDir() => platformCacheDir();

/// The licences of whatever this platform bundles for voice mode, which is
/// Silero's detector where there is one and nothing in a browser.
void registerVoiceLicences() => platformRegisterVoiceLicences();

/// The downloaded voice models, and what runs them. Two rather than one because
/// settings manages models with nothing listening, and a session needs the
/// store to find what it has been told to load.
VoiceModelStore createVoiceModelStore(String cacheDir) =>
    platformVoiceModelStore(cacheDir);

Voice createVoice(VoiceModelStore store, String cacheDir) =>
    platformVoice(store, cacheDir);

/// Ask the platform not to throw away what we wrote. Only a browser has
/// anything to say here.
Future<void> persist() => platformPersist();

ChatStore createChatStore(AppConfig config) => FileChatStore(config);

/// What a workspace file can do outside Entoli: a viewer, a file manager, a
/// share sheet, a download. The one part of the app that still varies three
/// ways rather than two, since desktop and Android disagree as much as either
/// does with a browser.
FileHandoff createFileHandoff(AppConfig config) => platformFileHandoff(config.fs);

/// Where a backup goes on its way out, and where one comes back from. Takes
/// the [handoff] because Android's route out is the share sheet, which is
/// already that port's.
BackupHandoff createBackupHandoff(AppConfig config, FileHandoff handoff) =>
    platformBackupHandoff(config.fs, handoff);

/// The system's assistant gesture. Android forwards it as an `ACTION_ASSIST`
/// intent; everywhere else nothing fires, which is what leaves the launch
/// handler inert.
AssistantLaunch createAssistantLaunch() => platformAssistantLaunch();

/// The presets, and the user's own beside them. Their directory is on the
/// config's filesystem, so it exists on every platform now.
List<PromptSource> createPromptSources(AppConfig config) =>
    [const BundledPrompts(), DirectoryPrompts(config)];
