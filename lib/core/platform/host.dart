import "dart:async";
import "dart:ffi";
import "dart:io";
import "dart:math" show min;

import "package:ffi/ffi.dart";
import "package:flutter/services.dart" show MethodChannel;
import "package:path/path.dart" as p;
import "package:entoli_core/model/model_budget.dart";
import "package:entoli_core/model/model_process.dart";
import "package:entoli_core/model/app_settings.dart";
import "package:entoli_core/model/agent_browser.dart";
import "package:entoli_core/model/app_update.dart";
import "package:entoli_core/model/log.dart";
import "package:entoli_core/model/assistant_launch.dart";
import "package:entoli_core/model/intent_action.dart";
import "package:entoli_core/model/builtin_project.dart";
import "package:entoli_core/model/file_watches.dart";
import "package:entoli_core/model/reminder_alarms.dart";
import "package:entoli_core/model/rootfs_store.dart";
import "package:entoli_core/model/secret_store.dart";
import "package:entoli_core/model/shell.dart";
import "package:entoli_core/model/sync/lan_signaling.dart";
import "package:entoli_core/model/voice.dart";
import "package:entoli_core/model/voice_model_store.dart";
import "package:entoli_core/model/config.dart";
import "package:entoli_paths/entoli_paths.dart" show appDirectories;
import "package:entoli_voice/entoli_voice.dart"
    show openVoiceModelStore, platformVoice;
import "package:entoli_shell/entoli_shell.dart"
    show BundledTools, LocalShell, environmentWithoutAppImage, openRootfsStore;
import "package:entoli_browser/entoli_browser.dart"
    show CdpBrowser, HeliumDownload;
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
import "../../data/local/system_device_name.dart";
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
import "../../data/tls.dart" show tlsClient;
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
/// Agent Browser picked, under `<cache>/browser/`; on the phones the app's
/// own web views.
AgentBrowser createAgentBrowser(AppConfig config, String cacheDir) {
  final dir = p.join(cacheDir, "browser");
  return CdpBrowser(
    browserDir: dir,
    picked: () => AppSettings.load(config).agentBrowser,
    visible: () => AppSettings.load(config).agentBrowserVisible,
    environment: environmentWithoutAppImage,
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
            launch: probe.memory,
            memory: _appleMemory,
            budgetRequired: Platform.isIOS,
          )
        : const NoLocalEngine();
  }
  if (!Platform.isAndroid && !Platform.isLinux) return const NoLocalEngine();
  // Asked alongside the library directory rather than after it: on Android
  // both are a channel round trip, and this is on the way to the first frame.
  final memory = _ramMemory();
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
    launch: await memory,
    // Android's RAM cannot change, so its launch reading stands.
    memory: Platform.isAndroid ? null : _ramMemory,
  );
}

/// Where both engines keep prompts — llama.cpp's `--slot-save-path` among
/// them: one join so the two cannot disagree.
String _kvCacheDir(String cacheDir) => p.join(cacheDir, "kv-cache");

/// What llama.cpp may have of this device: its RAM, asked of Android and read
/// off `/proc/meminfo` on Linux. Null where neither answers, which offers
/// every model.
Future<DeviceMemory?> _ramMemory() async => Platform.isAndroid
    ? androidMemoryOf(await BundledTools.totalMemory())
    : linuxMemoryOf(_readMeminfo());

/// Android's RAM, of which llama.cpp gets [ModelBudget.android]'s half.
DeviceMemory? androidMemoryOf(int? total) => total == null
    ? null
    : DeviceMemory(
        total: total,
        budget: ModelBudget.android(total),
        readings: [(label: "RAM", bytes: total)],
      );

/// Linux's RAM out of [meminfo], with what is still free beside it.
DeviceMemory? linuxMemoryOf(String? meminfo) {
  final total = linuxTotalMemory(meminfo);
  if (total == null) return null;
  final available = procBytes(meminfo, "MemAvailable");
  return DeviceMemory(
    total: total,
    budget: ModelBudget.linux(total),
    readings: [
      (label: "RAM", bytes: total),
      if (available != null) (label: "Available", bytes: available),
    ],
  );
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
    return AppleFmProbe(
      handshake["reason"] as String? ?? "other",
      mlx: handshake["mlx"] as bool? ?? false,
      memory: appleMemoryOf(handshake["memory"], mac: Platform.isMacOS),
    );
  } catch (e) {
    logFailure("apple-fm", "handshake failed", e);
    return null;
  }
}();

Future<AppleFmProbe?>? _appleHandshake;

/// The channel's `memory` [answer]: Metal's working set, and on a phone what
/// the OS still lets the app grow by. A phone's binding limit is the one it
/// may not have said, and a budget without it would be the Mac's guess: the
/// reading is still shown, its budget unknown.
DeviceMemory? appleMemoryOf(Object? answer, {required bool mac}) {
  final memory = answer as Map<Object?, Object?>? ?? const {};
  final graphics = memory["workingSet"] as int?;
  final headroom = memory["available"] as int?;
  if (graphics == null) return null;
  final shown = (label: "Graphics memory", bytes: graphics);
  if (mac || headroom == null) {
    return DeviceMemory(
      total: graphics,
      budget: mac ? ModelBudget.mac(graphics) : const ModelBudget.unknown(),
      readings: [shown],
    );
  }
  return DeviceMemory(
    total: min(graphics, headroom),
    budget: ModelBudget.phone(workingSet: graphics, available: headroom),
    readings: [shown, (label: "App headroom", bytes: headroom)],
  );
}

/// The handshake's readings asked again: the headroom moves as the app grows.
/// Null on a failure, so a missing reading leaves the models' own standing.
Future<DeviceMemory?> _appleMemory() async {
  try {
    final answer = await appleChannel
        .invokeMethod<Object?>("memory")
        .timeout(const Duration(seconds: 3));
    _memoryFailing = false;
    return appleMemoryOf(answer, mac: Platform.isMacOS);
  } catch (e) {
    // Polled every few seconds: a run of failures is one line.
    if (!_memoryFailing) logFailure("apple-fm", "memory reading failed", e);
    _memoryFailing = true;
    return null;
  }
}

bool _memoryFailing = false;

/// The bundle's `lib/` beside the running executable, the one its `$ORIGIN`
/// rpath resolves. Takes [executablePath] so a test can pin each shape.
String bundledLinuxLibDir({String? executablePath}) {
  final path = executablePath ?? Platform.resolvedExecutable;
  final dir = p.dirname(path);
  return p.basename(dir) == "lib" ? dir : p.join(dir, "lib");
}

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

/// Where this platform keeps the app's data and cache, resolved once.
final _directories = appDirectories(home: LocalShell.machineHomeDir());

/// `$ENTOLI_CONFIG` if set, else where this platform keeps the app's data.
Future<String> dataDir() async =>
    processEnv("ENTOLI_CONFIG") ?? await _directories.data;

/// Where things that can be fetched again live: `$ENTOLI_CACHE` if set, else
/// the platform's cache directory.
Future<String> cacheDir() async =>
    processEnv("ENTOLI_CACHE") ?? await _directories.cache;

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

/// What this machine calls itself, for the sync device name. A phone's
/// `localHostname` is "localhost", so the system device name is read instead.
Future<String?> deviceHostname() async {
  if (Platform.isAndroid || Platform.isIOS) return SystemDeviceName.read();
  try {
    final name = Platform.localHostname.trim();
    // A machine with no hostname of its own answers localhost.
    return name.isEmpty || name == "localhost" ? null : name;
  } catch (_) {
    return null;
  }
}
