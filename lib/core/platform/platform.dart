import "dart:convert";

import "package:fs_shim/fs.dart";

import "../../data/builtin/builtin_agent.dart";
import "../../data/builtin/builtin_backend.dart";
import "../../data/builtin/templates.dart";
import "../../data/builtin/llm/llm_client.dart";
import "../../data/builtin/llm/llm_registry.dart";
import "../../data/builtin/llm/local_kv_cache.dart";
import "../../data/builtin/llm/local_pool_client.dart";
import "../../data/builtin/llm/local_prefill.dart";
import "../../data/local/file_chat_store.dart";
import "../../data/prompts/prompt_sources.dart";
import "../../domain/app_settings.dart";
import "../../domain/background_work.dart";
import "../../domain/assistant_launch.dart";
import "../../domain/backup_handoff.dart";
import "../../domain/chat_store.dart";
import "../../domain/file_handoff.dart";
import "../../domain/local_llm.dart";
import "../../domain/local_model_store.dart";
import "../../domain/models.dart";
import "../../domain/prompt_library.dart";
import "../../domain/reminder_alarms.dart";
import "../../domain/rootfs_store.dart";
import "../../domain/secret_store.dart";
import "../../domain/shell.dart";
import "../../domain/sync/lan_signaling.dart";
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
BuiltinBackend createBackend(
  AppConfig config,
  PromptLibrary library,
  ChatStore store, {
  Toolset? tools,
  RootfsStore? rootfs,
  String? abi,
  required LocalLlm localLlm,
  LocalKvCache? kvCache,
}) {
  AppSettings settings() => AppSettings.load(config);
  return BuiltinBackend(
    config: config,
    library: library,
    shell: platformShell(
      environment: () => settings().environment,
      // Resolved per command rather than once: a Linux installed from the
      // settings page reaches the next command, and one deleted stops being
      // where commands run without the app having to be restarted.
      driver: () => platformDriver(
        skillsBundledDir: config.bundledSkillsDir,
        userSkillsDir: config.fs.path.join(config.dataDir, "skills"),
        tools: tools,
        proot: tools?.proot,
        store: rootfs,
        rootfsId: settings().rootfsId,
        abi: abi,
      ),
    ),
    webSearch: platformWebSearch(),
    store: store,
    registry: LlmRegistry(
      endpoints: () => llmEndpoints(settings, localLlm, kvCache),
      // Settings wins, but a key already exported is found without having to
      // be pasted in.
      lookupEnv: (name) => settings().environment[name] ?? processEnv(name),
    ),
  );
}

/// The on-device prompt warm-up, built where the shell that words the system
/// prompt and the server it warms both are. Null where there is no server —
/// every platform but Android. It reads the settings fresh on each run for the
/// reason the pool's client does: they are edited between turns.
///
/// The warm-up prompt is `systemPrompt` and nothing else — the body a real turn
/// sends as its first system message, with the per-chat `turnPrompt` that
/// follows it left off. That is what makes the warm-up's shortest key equal to
/// every chat's: the two hash the same message. The tools are [agentTools] with
/// the defaults a normal chat on this device has, for the same reason.
LocalPrefill? createLocalPrefill(
  BuiltinBackend backend,
  LocalLlm localLlm,
  BackgroundWork background,
  AppConfig config, {
  LocalKvCache? kvCache,
}) {
  if (!localLlm.available) return null;
  final shell = backend.shell;
  return LocalPrefill(
    llm: localLlm,
    background: background,
    kvCache: kvCache,
    // One settings read per warm, feeding both the serve options and the
    // prompt, so the two cannot be built from different snapshots.
    warmup: () {
      final now = AppSettings.load(config);
      // What a default top-level turn is offered: the device's facts, no
      // project's takes, nothing headless. A turn a built-in project narrows
      // misses the warmed prefix rather than the cache serving a list no turn
      // sends.
      final caps = AgentCapabilities.forTurn(
        commands: shell.canRunCommands,
        webSearch: backend.webSearch.available,
        disabled: const {},
      );
      return (
        options: poolOptions(now),
        messages: [
           agentSystemMessage(
             platform: shell.platformDescription,
             profile: now.profile,
             caps: caps,
             // The same skills a turn's prompt lists, off the same library the
             // backend holds — a warm-up built without them caches a prefix no
             // chat ever sends.
             skills: backend.library?.entries(CompletionKind.skill) ?? const [],
           ),
          const LlmMessage(role: LlmRole.user, text: "Hello"),
        ],
         tools: agentTools(
            caps: caps,
            skills: backend.library?.entries(CompletionKind.skill) ?? const [],
            // A default turn has auto-memory off, so the warmed prefix carries
           // no memory tools; a turn with them misses the cache rather than
           // the cache serving a list no turn sends.
           offerMemory: false,
         ),
      );
    },
  );
}

/// Every endpoint the app can reach: what the user configured, and the models
/// on this device where there are any.
///
/// The local one is composed here rather than written into `settings.json`
/// because it has no address to write — each model is its own process on a port
/// asked of the OS when it loads. So it carries its own client, which is what
/// routes a request to the right one and loads it on the way. Null while
/// nothing is downloaded, which is what keeps it out of every picker on the
/// platforms that have no server.
///
/// **First in the list, and that decides a collision**: `localProviderId` is
/// the app's name, and a `settings.json` that happens to use it is shadowed
/// rather than allowed to take the models' own endpoint away from them.
List<LlmEndpoint> llmEndpoints(
  AppSettings Function() settings,
  LocalLlm localLlm,
  LocalKvCache? kvCache,
) {
  final local = localLlm.provider;
  return [
    if (local != null)
      LlmEndpoint(local, build: (config, apiKey) => LocalPoolClient(localLlm, () {
            // Read here rather than above: this client outlives any one turn,
            // and the settings page edits these between them.
            return poolOptions(settings());
          }, kvCache: kvCache)),
    for (final config in settings().llmProviders) LlmEndpoint(config),
  ];
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

/// The version this build was made from, out of the `version.json` Flutter
/// writes into every bundle. Reading it is the platform's, since where it lands
/// varies; the build number after the `+` is the build's own, and pubspec
/// carries none — see "What the app is".
///
/// Null if it could not be read, which About leaves the line out for rather
/// than a startup failing over a string nothing depends on.
Future<String?> appVersion() async {
  final source = await platformVersionJson();
  if (source == null) return null;
  try {
    final json = jsonDecode(source) as Map<String, dynamic>;
    final version = json["version"] as String?;
    final build = json["build_number"] as String?;
    if (version == null) return null;
    return build == null || build.isEmpty ? version : "$version+$build";
  } catch (_) {
    return null;
  }
}

/// Where a downloaded model is kept, and what runs one. Two calls rather than
/// one for the reason the voice models and the rootfs are: the settings page
/// manages what is installed with nothing listening, while the agent needs the
/// server to answer with.
LocalModelStore createLocalModelStore(String cacheDir) =>
    platformLocalModelStore(cacheDir);

Future<LocalLlm> createLocalLlm(LocalModelStore store, String cacheDir) =>
    platformLocalLlm(store, cacheDir);

/// Where a turn's KV is persisted between reloads, or null where there is no
/// server to persist for — every platform but Android. Built beside the pool
/// because the two have to agree on the directory the server writes into. See
/// [LocalKvCache].
LocalKvCache? createLocalKvCache(String cacheDir, LocalLlm localLlm) =>
    platformLocalKvCache(cacheDir, localLlm);

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

/// Where this device's sync secrets are held: the system keyring where one
/// exists, the plain file under the data directory where none does. See
/// [SecretStore] for what each of those means to the Sync page.
SecretStore createSecretStore(AppConfig config) => platformSecretStore(config);

/// The LAN rendezvous a desktop hosts while pairing. Null where the platform
/// cannot listen — a browser pairs as the joiner instead.
LanSignaling? createLanSignaling() => platformLanSignaling();

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

/// The system clock a reminder is set against: AlarmManager on Android,
/// nothing anywhere else yet.
ReminderAlarms createReminderAlarms() => platformReminderAlarms();

/// The presets, and the user's own beside them. Their directory is on the
/// config's filesystem, so it exists on every platform now. The bundled skills
/// are extracted to the config's filesystem first — `installBundledSkills`,
/// called before the library is built in `main`.
List<PromptSource> createPromptSources(AppConfig config) => [
      BundledPrompts(config: config),
      DirectoryPrompts(config),
    ];

/// What this machine calls itself, where it has a name. The sync device name
/// starts here, so two paired machines are told apart by something the user
/// already recognises rather than by a slice of a key fingerprint. On Android
/// this is the system device name, read through a method channel; on Linux the
/// hostname; null where the platform has none of its own (the web).
Future<String?> deviceHostname() => platformHostname();

/// Makes the skill directories read-only so a model running `bash` cannot
/// unintentionally write to them. No-op on the web (no bash). See
/// `platformChmodReadOnly`.
Future<void> chmodReadOnly(List<String> paths) => platformChmodReadOnly(paths);

/// Toggles a directory writable for [action], then restores it read-only. The
/// install and delete paths use this — they are the app's writes, not the
/// model's.
Future<T> withWritableDir<T>(
        String path, Future<T> Function() action) =>
    platformWithWritableDir(path, action);
