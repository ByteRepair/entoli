import "dart:async";
import "dart:ffi";
import "dart:io";

import "package:file/local.dart";
import "package:ffi/ffi.dart";
import "package:flutter/foundation.dart";
import "package:flutter/services.dart" show MethodChannel;
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";
import "package:path_provider_foundation/path_provider_foundation.dart";
import "package:entoli_core/model/model_budget.dart";
import "package:entoli_core/model/model_process.dart";
import "package:entoli_core/model/app_settings.dart";
import "package:entoli_core/model/agent_browser.dart";
import "package:entoli_core/model/app_update.dart";
import "package:entoli_core/model/log.dart";
import "package:entoli_core/model/migrations.dart";
import "package:entoli_core/model/assistant_launch.dart";
import "package:entoli_core/model/intent_action.dart";
import "package:entoli_core/model/backup_handoff.dart";
import "package:entoli_core/model/builtin_project.dart";
import "package:entoli_core/model/file_handoff.dart";
import "package:entoli_core/model/file_watches.dart";
import "package:entoli_core/model/reminder_alarms.dart";
import "package:entoli_core/model/rootfs_store.dart";
import "package:entoli_core/model/secret_store.dart";
import "package:entoli_core/model/shell.dart";
import "package:entoli_core/model/sync/lan_signaling.dart";
import "package:entoli_core/model/voice.dart";
import "package:entoli_core/model/voice_model_store.dart";
import "package:entoli_core/model/config.dart";
import "package:entoli_files/entoli_files.dart"
    show platformBackupHandoff, platformFileHandoff;
import "package:entoli_voice/entoli_voice.dart"
    show openVoiceModelStore, platformVoice;
import "package:entoli_shell/entoli_shell.dart"
    show BundledTools, LocalShell, excludeFromBackup, openRootfsStore;
export "package:entoli_shell/entoli_shell.dart"
    show
        captureLoginPath,
        cliGuestOf,
        deleteTree,
        deviceAbi,
        hostConfinement,
        hostToolsDirIn,
        installBundledTools,
        linuxHostOf,
        platformDriver,
        platformShell,
        readOnlyDirs;

import "../../data/download.dart" show startDownload;
import "../../data/local/android_assistant_launch.dart";
import "../../data/local/android_device_name.dart";
import "../../data/local/android_reminder_alarms.dart";
import "../../data/local/byte_repair_store.dart";
import "../../data/local/file_secret_store.dart";
import "../../data/local/ios_reminder_alarms.dart";
import "../../data/local/file_local_model_store.dart";
import "../../data/local/llama_engine.dart";
import "../../data/local/llama_server.dart";
import "../../data/local/local_engine.dart";
import "../../data/local/mlx_engine.dart";
import "../../data/local/model_format.dart";
import "../../data/local/prompt_cache.dart";
import "../../data/local/apple_fm.dart";
import "../../data/model_host/helper_process.dart";
import "../../data/model_host/model_process.dart";
import "../../data/local/intent_channel.dart";
import "../../data/local/io_file_watches.dart";
import "../../data/local/linux_reminder_alarms.dart";
import "../../data/local/macos_reminder_alarms.dart";
import "../../data/browser/cdp_browser.dart";
import "../../data/browser/helium.dart";
import "../tls.dart" show tlsClient;
import "form_factor.dart" show isPhone;
import "keyring_secret_store.dart";
import "signaling_server.dart";
import "update.dart";

/// Where the CLI programs and their sessions' folders are kept: the cache,
/// except on iOS, where the emulator sees the app's data directory at its
/// own path and nothing else of the host.
String cliCacheRoot({required String cache, required String dataDir}) =>
    Platform.isIOS ? p.join(dataDir, "cli-cache") : cache;

AppUpdateHost createAppUpdateHost(String cacheDir) {
  final flavour = Platform.isLinux
      ? UpdateFlavour.linux
      : Platform.isMacOS
      ? UpdateFlavour.macos
      : Platform.isWindows
      ? UpdateFlavour.windows
      : null;
  return flavour == null
      ? const UnavailableAppUpdateHost()
      : DesktopUpdater(flavour: flavour, cacheDir: cacheDir);
}

/// The browser the agent drives: on the three desktops whatever Settings >
/// Agent Browser picked, under `<cache>/browser/`; on Android the app's own
/// WebViews. iOS's WKWebView speaks no DevTools Protocol.
AgentBrowser createAgentBrowser(AppConfig config, String cacheDir) {
  final dir = p.join(cacheDir, "browser");
  return CdpBrowser(
    browserDir: dir,
    picked: () => AppSettings.load(config).agentBrowser,
    visible: () => AppSettings.load(config).agentBrowserVisible,
    embedded: HeliumDownload(dir, client: tlsClient),
    webViews: Platform.isAndroid || Platform.isIOS
        ? const MethodChannel("agent_chat/browser")
        : null,
  );
}

RootfsStore createRootfsStore(String cacheDir) =>
    openRootfsStore(cacheDir, startDownload());

/// Installs into the guest's `/usr/local/bin` on the phones (proot, iSH) and
/// the app's own bin directory on the desktops. A guest's `apk` installs in
/// minutes; a host install fetches a 240 MB ESBMC zip and wants the half hour.
ByteRepairStore createByteRepairStore(
  AppConfig config,
  String cacheDir,
  RootfsStore? rootfs,
) {
  final guest = Platform.isAndroid || Platform.isIOS;
  final project = ByteRepairProject().dir;
  return ByteRepairStore(
    config: config,
    project: project,
    workspace: config.projectWorkspaceDir(project: project),
    installDir: guest ? guestEsbmcInstallDir : byteRepairBinDir(cacheDir),
    installTimeout: guest ? guestInstallTimeout : hostInstallTimeout,
    rootfsStore: rootfs,
    scratchDir: Platform.isIOS ? guestHome : null,
  );
}

/// The host bin directory a rootfs-isolated project's tools land in, or null
/// on the phones, whose setup installs inside the guest. The store's
/// `installDir` and the driver's `PATH` prefix are both derived from this, so
/// they cannot disagree.
String? byteRepairBinDir(String cacheDir) =>
    Platform.isLinux || Platform.isMacOS || Platform.isWindows
    ? p.join(cacheDir, "byte-repair", "bin")
    : null;

/// Whether a project's `.setup-complete` marker is there. Synchronous because
/// the chat page asks it in a build.
///
/// On the host the binary must be there too: the tools live in a cache the OS
/// may empty. On a phone a rootfs must be picked, since without one there is
/// no shell to stand the setup up again in.
bool setupComplete(AppConfig config, String? project, String? binDir) {
  if (isPhone && AppSettings.load(config).rootfsId == null) {
    return false;
  }
  if (!File(config.setupCompleteFile(project: project)).existsSync()) {
    return false;
  }
  if (binDir == null) return true;
  return File(p.join(binDir, esbmcFileName)).existsSync();
}

/// What runs downloaded models here. Android and Linux run llama.cpp's server
/// where this build carried one: Android's native library directory (the one
/// place an app may exec from), or the Linux bundle's `lib/`. A machine's own
/// llama.cpp is reached as a provider instead. iOS and macOS run MLX where the
/// handshake says the build links it and the OS can run it.
Future<LocalEngine> createLocalEngine(String cacheDir) async {
  if (Platform.isIOS || Platform.isMacOS) {
    final probe = await _appleProbe();
    return probe != null && probe.mlx
        ? MlxEngine(
            FileLocalModelStore(
              p.join(cacheDir, "llm"),
              format: const MlxFormat(),
            ),
            _modelProcess,
            prompts: PromptCache(_kvCacheDir(cacheDir)),
            budget: probe.budget,
          )
        : const NoLocalEngine();
  }
  if (!Platform.isAndroid && !Platform.isLinux) return const NoLocalEngine();
  // Asked alongside the library directory rather than after it: on Android
  // both are a channel round trip, and this is on the way to the first frame.
  final budget = _memoryBudget();
  final (String? libDir, String serverName) = Platform.isAndroid
      ? (await BundledTools.nativeLibraryDir(), "libllama-server.so")
      : (bundledLinuxLibDir(), "llama-server");
  if (libDir == null) return const NoLocalEngine(missingFromBuild: true);
  final server = p.join(libDir, serverName);
  if (!File(server).existsSync()) {
    return const NoLocalEngine(missingFromBuild: true);
  }
  final store = FileLocalModelStore(
    p.join(cacheDir, "llm"),
    format: const GgufFormat(),
  );
  final prompts = PromptCache(_kvCacheDir(cacheDir));
  return LlamaEngine(
    LlamaRuntime(
      LlamaBinaries(server: server, libDir: libDir),
      slotSaveDir: prompts.dir,
      fitLayers: !Platform.isAndroid,
    ),
    store,
    prompts: prompts,
    budget: await budget,
  );
}

/// Where both engines keep prompts — llama.cpp's `--slot-save-path` among
/// them: one join so the two cannot disagree.
String _kvCacheDir(String cacheDir) => p.join(cacheDir, "kv-cache");

/// What llama.cpp may have of this device: its RAM, asked of Android and read
/// off `/proc/meminfo` on Linux. Unknown where neither answers, which offers
/// every model.
Future<ModelBudget> _memoryBudget() async {
  if (Platform.isAndroid) {
    final total = await BundledTools.totalMemory();
    return total == null
        ? const ModelBudget.unknown()
        : ModelBudget.android(total);
  }
  final total = linuxTotalMemory(_readMeminfo());
  return total == null ? const ModelBudget.unknown() : ModelBudget.linux(total);
}

String? _readMeminfo() {
  try {
    return File("/proc/meminfo").readAsStringSync();
  } on FileSystemException {
    return null;
  }
}

/// `MemTotal` out of [meminfo], in bytes. Null where it is not there.
int? linuxTotalMemory(String? meminfo) => procBytes(meminfo, "MemTotal");

/// [AppleFm] where the device could carry Apple's on-device model. Hardware
/// that never could is null, out of every picker; a model that is merely not
/// enabled yet keeps its endpoint, and a turn's failure says why, since that
/// can flip mid-session.
Future<AppleFm?> createAppleFm() async {
  final probe = await _appleProbe();
  return switch (probe?.reason) {
    null || "device-not-eligible" || "os" => null,
    _ => AppleFm(probe!),
  };
}

/// The channel's handshake, asked once for both the Apple model and the MLX
/// engine: null where there is no channel to ask.
Future<AppleFmProbe?> _appleProbe() => _appleHandshake ??= () async {
  if (!Platform.isIOS && !Platform.isMacOS) return null;
  try {
    final answer = await appleChannel
        .invokeMethod<Object?>("handshake")
        .timeout(const Duration(seconds: 3));
    final handshake = answer as Map<Object?, Object?>? ?? const {};
    final memory = handshake["memory"] as Map<Object?, Object?>? ?? const {};
    final workingSet = memory["workingSet"] as int?;
    final available = memory["available"] as int?;
    return AppleFmProbe(
      handshake["reason"] as String? ?? "other",
      mlx: handshake["mlx"] as bool? ?? false,
      // A phone's binding limit is the one it may not have said, and a
      // budget without it would be the Mac's guess: nothing measured then.
      budget: switch ((workingSet, available)) {
        (final workingSet?, _) when Platform.isMacOS => ModelBudget.mac(
          workingSet,
        ),
        (final workingSet?, final available?) => ModelBudget.phone(
          workingSet: workingSet,
          available: available,
        ),
        _ => const ModelBudget.unknown(),
      },
    );
  } catch (e) {
    logFailure("apple-fm", "handshake failed", e);
    return null;
  }
}();

Future<AppleFmProbe?>? _appleHandshake;

/// The bundle's `lib/` beside the running executable, the one its `$ORIGIN`
/// rpath resolves. Takes [executablePath] so a test can pin each shape.
String bundledLinuxLibDir({String? executablePath}) {
  final path = executablePath ?? Platform.resolvedExecutable;
  final dir = p.dirname(path);
  return p.basename(dir) == "lib" ? dir : p.join(dir, "lib");
}

FileHandoff createFileHandoff() => platformFileHandoff();

BackupHandoff createBackupHandoff(FileHandoff handoff) =>
    platformBackupHandoff(handoff);

/// Shortcuts' App Intents, on the two platforms that have them: the Apple
/// Runners answer `agent_chat/intents`, and nothing else does.
void listenForIntents(IntentRegistry registry) {
  if (Platform.isIOS || Platform.isMacOS) {
    unawaited(IntentChannel(registry).listen());
  }
}

AssistantLaunch createAssistantLaunch() => Platform.isAndroid
    ? AndroidAssistantLaunch()
    : const UnavailableAssistantLaunch();

/// AlarmManager on Android, launchd on macOS, local notifications on iOS, the
/// session bus on Linux. Windows has none, so reminders ride the app's timer.
Future<ReminderAlarms> createReminderAlarms() async {
  if (Platform.isAndroid) return AndroidReminderAlarms();
  if (Platform.isIOS) return IosReminderAlarms();
  if (Platform.isLinux) return connectLinuxReminderAlarms();
  // The data directory names the launchd jobs, so copies pointed at
  // different stores never share a namespace.
  if (Platform.isMacOS) return MacosReminderAlarms(await dataDir());
  return const UnavailableReminderAlarms();
}

FileWatches createFileWatches() => IoFileWatches();

/// `$ENTOLI_CONFIG` if set, else `~/.config/entoli` on desktop and
/// app-private storage on the phones. A desktop debug build uses
/// `entoli-debug`, so it never touches an installed copy's data; a
/// phone's debug build is its own app, its storage already apart.
Future<String> dataDir() async {
  final override = processEnv("ENTOLI_CONFIG");
  return override ?? p.join(await _resolveBase(), _dirLeaf);
}

String get _dirLeaf =>
    (Platform.isLinux || Platform.isMacOS || Platform.isWindows) && kDebugMode
    ? "entoli-debug"
    : "entoli";

Future<String> _resolveBase() async {
  if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
    return p.join(_home, ".config");
  }
  if (Platform.isIOS) return _iosBase;
  final dir = await getApplicationDocumentsDirectory();
  return dir.path;
}

/// The App Group the Runner shares with its File Provider extension, which
/// reads the workspaces from the data directory inside it. See "The
/// workspaces in the Files app" in ios/AGENTS.md.
const iosAppGroup = "group.io.byterepair.entoli";

/// Resolved once per process, since resolving it may move the directory.
final Future<String> _iosBase = _resolveIosBase();

/// The App Group's container, once `relocateDataDir` has moved a data
/// directory from before it out of Documents. Documents stays where the move
/// fails, so the app still runs; the Files app then shows nothing until a
/// launch where it lands.
Future<String> _resolveIosBase() async {
  final group = await PathProviderFoundation().getContainerPath(
    appGroupIdentifier: iosAppGroup,
  );
  // Every launch after the move ends here, with no need of Documents.
  if (group != null && Directory(p.join(group, _dirLeaf)).existsSync()) {
    return group;
  }
  final documents = (await getApplicationDocumentsDirectory()).path;
  if (group == null) {
    logFailure("files", "no App Group container, data stays in Documents");
    return documents;
  }
  final moved = relocateDataDir(
    const LocalFileSystem(),
    from: p.join(documents, _dirLeaf),
    to: p.join(group, _dirLeaf),
  );
  return moved ? group : documents;
}

String get _home => LocalShell.machineHomeDir()!;

/// Where things that can be fetched again live. `$ENTOLI_CACHE` if set,
/// else the platform's cache directory, named by hand so it pairs with
/// `~/.config/entoli`.
///
/// **Android uses the support directory, deliberately**: `getCacheDir()` is
/// emptied under storage pressure and by Clear Cache, and a model the user
/// chose to download is not something to lose that way.
Future<String> cacheDir() async {
  final override = processEnv("ENTOLI_CACHE");
  if (override != null) return override;
  if (Platform.isLinux) {
    final xdg = Platform.environment["XDG_CACHE_HOME"];
    return p.join(xdg ?? p.join(_home, ".cache"), _dirLeaf);
  }
  if (Platform.isMacOS) return p.join(_home, "Library", "Caches", _dirLeaf);
  if (Platform.isWindows) {
    final local =
        Platform.environment["LOCALAPPDATA"] ??
        p.join(_home, "AppData", "Local");
    return p.join(local, _dirLeaf, "Cache");
  }
  final dir = p.join((await getApplicationSupportDirectory()).path, "entoli");
  // iOS backs up Application Support, and Caches is purged under storage
  // pressure, which a downloaded model must survive. Apple's answer for data
  // that is refetchable yet kept is this, with the backup flag set.
  if (Platform.isIOS) {
    Directory(dir).createSync(recursive: true);
    if (!excludeFromBackup(dir)) {
      logFailure("files", "could not exclude the cache from backup");
    }
  }
  return dir;
}

VoiceModelStore createVoiceModelStore(String cacheDir) =>
    openVoiceModelStore(cacheDir, startDownload());

/// Where this process's on-device models run, one for the process so MLX and
/// voice share it: a model host on macOS, where MLX's GPU work beside the
/// window starves the window's frames, and this process everywhere else. See
/// "The model host" in macos/AGENTS.md. Only an app bundle has an executable
/// to launch again, so a macOS process outside one runs them here too.
final ModelProcess _modelProcess = Platform.isMacOS && HelperProcess.canLaunch
    ? HelperModelProcess(HelperProcess.launch)
    : const InAppModelProcess();

Voice createVoice(VoiceModelStore store, String cacheDir) =>
    platformVoice(store, cacheDir, _modelProcess);

/// The process's environment. The Dart VM's iOS build leaves
/// `Platform.environment` empty, so a launch variable never reached a
/// provider's `apiKeyEnv` there; libc's `getenv` reads the real one.
String? processEnv(String name) =>
    Platform.isIOS ? _getenv(name) : Platform.environment[name];

final _libcGetenv = DynamicLibrary.process()
    .lookupFunction<
      Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)
    >("getenv");

String? _getenv(String name) {
  final key = name.toNativeUtf8();
  try {
    final value = _libcGetenv(key);
    return value == nullptr ? null : value.toDartString();
  } finally {
    malloc.free(key);
  }
}

/// The desktop keyring where a Secret Service answers, else the plain file.
/// Only Linux has a Secret Service to ask.
SecretStore createSecretStore(AppConfig config) => Platform.isLinux
    ? KeyringSecretStore(FileSecretStore(config))
    : FileSecretStore(config);

LanSignaling? createLanSignaling() => SignalingServer();

/// What this machine calls itself, for the sync device name. Android's
/// `localHostname` is "localhost", so the system device name is read instead.
Future<String?> deviceHostname() async {
  if (Platform.isAndroid) return AndroidDeviceName.read();
  try {
    final name = Platform.localHostname.trim();
    return name.isEmpty ? null : name;
  } catch (_) {
    return null;
  }
}
