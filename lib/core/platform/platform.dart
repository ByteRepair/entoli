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
import "../../data/local/byte_repair_store.dart" show ByteRepairStore;
import "../../data/prompts/prompt_sources.dart";
import "../../domain/app_settings.dart";
import "../../domain/app_secrets.dart";
import "../../domain/background_work.dart";
import "../../domain/assistant_launch.dart";
import "../../domain/backup_handoff.dart";
import "../../domain/builtin_project.dart";
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
  required LocalLlm localLlm,
  LocalKvCache? kvCache,
  String? byteRepairBinDir,
  required AppSecrets secrets,
  String? loginPath,
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
    ),
    webSearch: platformWebSearch(),
    store: store,
    registry: LlmRegistry(
      endpoints: () => llmEndpoints(settings, localLlm, kvCache),
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
             skills: backend.libraryFor(null)?.entries(CompletionKind.skill) ?? const [],
           ),
          const LlmMessage(role: LlmRole.user, text: "Hello"),
        ],
         tools: agentTools(
            caps: caps,
            skills: backend.libraryFor(null)?.entries(CompletionKind.skill) ?? const [],
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

/// The Byte Repair tooling store, over that rootfs store. Which project it is
/// for and where its fetched tools land are decided here rather than in each
/// side of the conditional import, so the two cannot disagree — and so the
/// store the turns' driver injects on PATH and the store that fills it are
/// built from the one directory. [cacheDir] is the resolved cache directory;
/// where the install goes is the platform side's to answer.
ByteRepairStore createByteRepairStore(
        AppConfig config, String cacheDir, RootfsStore? rootfs) =>
    platformByteRepairStore(
      config,
      ByteRepairProject().dir,
      config.projectWorkspaceDir(project: ByteRepairProject().dir),
      cacheDir,
      rootfs,
    );

/// The bin directory the host side injects on PATH for rootfs-isolated
/// projects, or null where there is none. Resolved from the same cache
/// directory the store was, so the two cannot disagree.
String? byteRepairBinDir(String cacheDir) => platformByteRepairBinDir(cacheDir);

/// Whether a project that requires setup has its `.setup-complete` marker.
/// Synchronous because the chat page asks it in a build; true on the web,
/// where nothing could write the marker and nothing is gated by it.
bool setupComplete(AppConfig config, String? project, String? binDir) =>
    platformSetupComplete(config, project, byteRepairBinDir: binDir);

Future<String?> deviceAbi() => platformAbi();

/// The version this build was made from, out of the `version.json` asset.
/// `tool/prepare.sh` writes it from pubspec's `version:`, and it is declared
/// in pubspec so every platform's bundle carries it — Flutter only writes its
/// own for Linux and Web, which overrides ours where one exists. The build
/// number is the build's own and not reported — see "What the app is".
///
/// Null if it could not be read, which About leaves the line out for rather
/// than a startup failing over a string nothing depends on.
Future<String?> appVersion() async {
  final source = await platformVersionJson();
  if (source == null) return null;
  try {
    return (jsonDecode(source) as Map<String, dynamic>)["version"] as String?;
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

/// The recorder voice mode's microphone runs on, where the platform has one
/// of its own to register.
void registerRecorder() => platformRegisterRecorder();

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

/// The system clock a reminder is set against: AlarmManager on Android, the
/// session bus's notifications on Linux, nothing anywhere else.
Future<ReminderAlarms> createReminderAlarms() => platformReminderAlarms();

/// The presets, and the user's own beside them. Their directory is on the
/// config's filesystem, so it exists on every platform now. The bundled
/// skills are extracted to the config's filesystem first — `installBundledSkills`,
/// called before the library is built in `main`. [project] is the project
/// whose overrides are layered on top of the default set; `null` is the
/// default project, the way it is everywhere else a project is named.
List<PromptSource> createPromptSources(AppConfig config, {String? project}) => [
      BundledPrompts(config: config, project: project),
      DirectoryPrompts(config, project: project),
    ];

/// What this machine calls itself, where it has a name. The sync device name
/// starts here, so two paired machines are told apart by something the user
/// already recognises rather than by a slice of a key fingerprint. On Android
/// this is the system device name, read through a method channel; on Linux the
/// hostname; null where the platform has none of its own (the web).
Future<String?> deviceHostname() => platformHostname();

/// The user's login shell's PATH, or null where there is nothing to ask — a
/// platform with no shell behind its commands, or a login shell this build
/// does not know how to read. Answered once per app run by `main.dart`, and
/// the answer reaches every command's driver after it; the capture is a
/// subprocess round trip, so it is never asked for where a driver is built.
Future<String?> captureLoginPath() => platformCaptureLoginPath();

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

/// Deletes a tree that may contain proot's mode-0000 bind stubs. The io side
/// delegates to `removeTree` (`tree_ops.dart`); the web side has no rootfs and
/// no stubs, so it is a plain recursive delete. Called by `restoreBackup` for
/// every top-level directory in the data dir — the stubs live deep inside a
/// `projects/<project>/rootfs/` tree, so the whole `projects/` entry has to go
/// through it. This is the same `removeTree` the rootfs stores use, so the one
/// function that knows how to clear a stub-bearing tree is the one the restore
/// reuses.
Future<void> deleteTree(String path) => platformDeleteTree(path);
