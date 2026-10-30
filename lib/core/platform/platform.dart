import "dart:convert";


import "../../data/builtin/builtin_agent.dart";
import "../../data/builtin/builtin_backend.dart";
import "../../data/builtin/tools/agent_tool.dart";
import "../../data/builtin/tools/registry.dart";
import "../../data/builtin/llm/llm_client.dart";
import "../../data/builtin/llm/llm_registry.dart";
import "../../data/builtin/llm/local_pool_client.dart";
import "../../data/builtin/llm/local_prefill.dart";
import "../../data/builtin/llm/providers/presets.dart";
import "../../data/local/file_chat_store.dart";
import "../../data/local/byte_repair_store.dart" show ByteRepairStore;
import "../../data/local/llama_engine.dart";
import "../../data/local/local_engine.dart";
import "../../data/prompts/prompt_sources.dart";
import "../../domain/agent_browser.dart";
import "../../domain/app_settings.dart";
import "../../domain/app_secrets.dart";
import "../../domain/background_work.dart";
import "../../domain/backup_handoff.dart";
import "../../domain/builtin_project.dart";
import "../../domain/chat_store.dart";
import "../../domain/file_handoff.dart";
import "../../domain/models.dart";
import "../../domain/prompt_library.dart";
import "../../domain/trigger_manager.dart" show TriggerRegistryFactory;
import "../../domain/rootfs_store.dart";
import "../../domain/shell.dart";
import "../config.dart";
import "io/platform.dart" if (dart.library.js_interop) "web/platform.dart";
import "../../data/builtin/builtin_options.dart";

export "io/platform.dart" if (dart.library.js_interop) "web/platform.dart"
    show
        processEnv,
        byteRepairBinDir,
        cacheDir,
        captureLoginPath,
        createAgentBrowser,
        createAppleFm,
        createAppUpdateHost,
        createAssistantLaunch,
        createFileSystem,
        createFileWatches,
        createLanSignaling,
        createLocalEngine,
        createReminderAlarms,
        createRootfsStore,
        createSecretStore,
        createVoice,
        createVoiceModelStore,
        dataDir,
        deleteTree,
        deviceAbi,
        deviceHostname,
        hostConfinement,
        installBundledTools,
        persist,
        registerRecorder,
        readOnlyDirs,
        registerVoiceLicences,
        setupComplete;

// The app's platform seam: everything platform-varying is resolved here or
// re-exported from the side that answers it.

/// The agent, wired to what this platform can reach and to whatever the
/// settings page last wrote. [libraries] is Entoli's commands and agents per
/// project — the default's is the base set every other project inherits. The
/// agent expands references itself, against the project's library. [store] is
/// the chat store, which the agent needs to write artifacts to the chat's
/// `artifacts/` dir.
BuiltinBackend createBackend(
  AppConfig config,
  Map<String?, PromptLibrary> libraries,
  ChatStore store, {
  Toolset? tools,
  RootfsStore? rootfs,
  String? abi,
  String? byteRepairBinDir,
  required AppSecrets secrets,
  String? loginPath,
  TriggerRegistryFactory? triggerRegistry,
  SettingsEditor? editSettings,
  AgentBrowser browser = const UnavailableAgentBrowser(),
  required List<LlmProvider> Function() endpoints,
  required bool cutsUtterances,
}) {
  AppSettings settings() => AppSettings.load(config);
  final backend = BuiltinBackend(
    config: config,
    shell: platformShell(
      environment: () => settings().environment,
      // Resolved per command rather than once: a Linux installed from the
      // settings page reaches the next command, and one deleted stops being
      // where commands run without the app having to be restarted.
      driver: ({String? project}) => platformDriver(
        defaultSkillsBundledDir: config.bundledSkillsDir(),
        defaultUserSkillsDir: config.promptsDir(CompletionKind.skill),
        projectSkillsBundledDir:
            project == null ? null : config.bundledSkillsDir(project: project),
        projectUserSkillsDir:
            project == null ? null : config.promptsDir(CompletionKind.skill, project: project),
        tools: tools,
        proot: tools?.proot,
        store: rootfs,
        rootfsId: settings().rootfsId,
        abi: abi,
        project: project,
        config: config,
        byteRepairBinDir: byteRepairBinDir,
        loginPath: loginPath,
      ),
      // iOS resolves its own shell (IshShell, not LocalShell) from these —
      // the driver callback above is exec-based and iOS denies a child
      // process. The id rides in as a thunk there too, so an install or a
      // deletion on the Terminal page reaches the next command.
      dataDir: config.dataDir,
      rootfsStore: rootfs,
      rootfsId: () => settings().rootfsId,
    ),
    webSearch: platformWebSearch(),
    browser: browser,
    store: store,
    triggerRegistry: triggerRegistry,
    editSettings: editSettings,
    registry: LlmRegistry(
      endpoints: endpoints,
      cutsUtterances: cutsUtterances,
      // Settings wins, but a key already exported is found without having to
      // be pasted in.
      lookupEnv: (name) => settings().environment[name] ?? processEnv(name),
      // The stored keys are the middle of the order in the registry: pasted
      // config wins over them, they win over a named variable.
      lookupKey: secrets.providerKey,
    ),
    // Read fresh per turn rather than captured: the slider is a setting, and
    // an edit reaches the next turn the way the environment does.
    options: BuiltinOptions(
        stepLimit: settings().turnMaxSteps ?? AppSettings.defaultTurnMaxSteps),
  );
  for (final entry in libraries.entries) {
    backend.setLibrary(entry.key, entry.value);
  }
  return backend;
}

/// The on-device prompt warm-up, built where the shell that words the system
/// prompt and the server it warms both are. Null where the engine is not
/// llama.cpp's. It reads the settings fresh on each run for the reason the
/// pool's client does: they are edited between turns.
///
/// The warm-up prompt is `systemPrompt` and nothing else — the body a real turn
/// sends as its first system message, with the per-chat `turnPrompt` that
/// follows it left off. That is what makes the warm-up's shortest key equal to
/// every chat's: the two hash the same message. The tools and the prompt are read off
/// one [ToolOffer] with the defaults a normal chat on this device has, for the
/// same reason.
LocalPrefill? createLocalPrefill(
  BuiltinBackend backend,
  LocalEngine engine,
  BackgroundWork background,
  AppConfig config,
) {
  if (engine is! LlamaEngine) return null;
  final shell = backend.shell;
  return LocalPrefill(
    llm: engine.llm,
    background: background,
    kvCache: engine.kvCache,
    // One settings read per warm, feeding both the serve options and the
    // prompt, so the two cannot be built from different snapshots.
    warmup: () {
      final now = AppSettings.load(config);
      // What a default top-level turn is offered: the device's facts, no
      // project's takes, nothing headless. A turn a built-in project narrows
      // misses the warmed prefix rather than the cache serving a list no turn
      // sends. The tone and citations answers are the app's for the same
      // reason: a project that pins its own in `project.json` sends a body
      // that differs here, and misses the prefix too — the app-level answer
      // is the one every chat shares.
      final offer = ToolOffer(
        caps: AgentCapabilities.forTurn(
          commands: shell.canRunCommands,
          webSearch: backend.webSearch.available,
          disabled: const {},
        ),
        // The same skills a turn's prompt lists, off the same library the
        // backend holds — a warm-up built without them caches a prefix no
        // chat ever sends.
        skills: backend.libraryFor(null)?.entries(CompletionKind.skill) ?? const [],
        // A default turn has auto-memory off, so the warmed prefix carries no
        // memory tools; a turn with them misses the cache rather than the
        // cache serving a list no turn sends. Every top-level chat has a
        // `resources/` to copy out of.
        attachments: true,
        background: shell.canRunInBackground,
      );
      return (
        options: poolOptions(now),
        messages: [
          agentSystemMessage(
            platform: shell.platformDescription,
            profile: now.profile,
            tone: now.tone,
            citations: now.citations,
            offer: offer,
          ),
          const LlmMessage(role: LlmRole.user, text: "Hello"),
        ],
        tools: [for (final tool in offeredTools(offer)) tool.definition],
      );
    },
  );
}

/// The Byte Repair tooling store. Which project it is for is decided here so
/// both sides of the conditional import agree on it.
ByteRepairStore createByteRepairStore(
        AppConfig config, String cacheDir, RootfsStore? rootfs) =>
    platformByteRepairStore(
      config,
      ByteRepairProject().dir,
      config.projectWorkspaceDir(project: ByteRepairProject().dir),
      cacheDir,
      rootfs,
    );

/// The version this build was made from, out of the `version.json` asset that
/// `tool/prepare.sh` writes from pubspec. Null if it could not be read, which
/// About leaves the line out for.
Future<String?> appVersion() async {
  final source = await platformVersionJson();
  if (source == null) return null;
  try {
    return (jsonDecode(source) as Map<String, dynamic>)["version"] as String?;
  } catch (_) {
    return null;
  }
}

ChatStore createChatStore(AppConfig config) =>
    FileChatStore(config, deleteTree: deleteTree, readOnlyDirs: readOnlyDirs);

FileHandoff createFileHandoff(AppConfig config) => platformFileHandoff(config.fs);

BackupHandoff createBackupHandoff(AppConfig config, FileHandoff handoff) =>
    platformBackupHandoff(config.fs, handoff);

/// The presets and the user's own beside them. [project]'s overrides are
/// layered on the default set; `null` is the default project.
List<PromptSource> createPromptSources(AppConfig config, {String? project}) => [
      BundledPrompts(config: config, project: project),
      DirectoryPrompts(config, project: project),
    ];
