import "dart:async";
import "dart:ffi";
import "dart:io";
import "dart:isolate";

import "package:ffi/ffi.dart";
import "package:flutter/foundation.dart";
import "package:flutter/services.dart" show MethodChannel, rootBundle;
import "package:record_platform_interface/record_platform_interface.dart"
    show RecordPlatform;
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

import "../../data/backup_handoff.dart";
import "../../data/local/android_assistant_launch.dart";
import "../../data/local/android_device_name.dart";
import "../../data/local/android_file_handoff.dart";
import "../../data/local/android_reminder_alarms.dart";
import "../../data/local/bundled_tools.dart";
import "../../data/local/byte_repair_store.dart";
import "../../data/local/file_secret_store.dart";
import "../../data/local/ios_reminder_alarms.dart";
import "../../data/local/file_kv_cache.dart";
import "../../data/local/file_modes.dart";
import "../read_only_dirs.dart";
import "../../data/local/file_local_model_store.dart";
import "../../data/local/file_rootfs_store.dart";
import "../../data/local/ish_ffi.dart";
import "../../data/local/ish_shell.dart";
import "../../data/local/llama_engine.dart";
import "../../data/local/llama_server.dart";
import "../../data/local/local_engine.dart";
import "../../data/local/mlx_engine.dart";
import "../../data/local/model_format.dart";
import "../../data/local/proot.dart";
import "../../data/local/apple_fm.dart";
import "../../data/local/landlock.dart";
import "../../data/local/shared_backup.dart";
import "../../data/local/tree_ops.dart";
import "../../data/local/desktop_file_handoff.dart";
import "../../data/local/io_file_watches.dart";
import "../../data/local/linux_reminder_alarms.dart";
import "../../data/local/macos_reminder_alarms.dart";
import "../../data/browser/cdp_browser.dart";
import "../../data/browser/helium.dart";
import "../tls.dart" show tlsClient;
import "../../data/builtin/local_shell.dart";
import "../../data/voice/android_voice.dart";
import "../../data/voice/file_voice_model_store.dart";
import "../../data/voice/ios_voice.dart";
import "../../data/voice/macos_voice.dart";
import "../../data/voice/sherpa_voice.dart";
import "../../domain/app_settings.dart";
import "../../domain/agent_browser.dart";
import "../../domain/app_update.dart";
import "../log.dart";
import "../../domain/assistant_launch.dart";
import "../../domain/confinement.dart";
import "../../domain/backup_handoff.dart";
import "../../domain/builtin_project.dart";
import "../../domain/file_handoff.dart";
import "../../domain/file_watches.dart";
import "../../domain/reminder_alarms.dart";
import "../../domain/rootfs.dart";
import "../../domain/rootfs_store.dart";
import "../../domain/secret_store.dart";
import "../../domain/shell.dart";
import "../../domain/sync/lan_signaling.dart";
import "../../domain/voice.dart";
import "../../domain/voice_model_store.dart";
import "../config.dart";
import "form_factor.dart" show isPhone;
import "keyring_secret_store.dart";
import "linux_recorder.dart";
import "signaling_server.dart";
import "update.dart";

Shell platformShell({
  required Map<String, String> Function() environment,
  required ShellDriver? Function({String? project}) driver,
  String? dataDir,
  RootfsStore? rootfsStore,

  /// Asked per command: which Linux the settings page has picked. Null where
  /// the platform has no picker at all.
  String? Function()? rootfsId,
}) {
  if (Platform.isIOS) {
    // No host shell and no proot: IshShell drives the emulator through FFI,
    // resolving the rootfs per command; the guest boots once, so a swap after
    // the first command is refused until a restart. See ios/AGENTS.md.
    String? rootfsDir() {
      final rootfs = rootfsById(rootfsId?.call());
      return rootfs != null ? rootfsStore?.directoryOfSync(rootfs.id) : null;
    }

    return IshShell(
      rootfsDir: () => rootfsDir() ?? "",
      dataDir: dataDir ?? "",
      environment: environment,
      platformDescription: () => rootfsDir() != null
          ? rootfsById(rootfsId?.call())!.describe("ios")
          : "iOS, with no Linux installed. Install one from the Terminal "
              "settings to run commands.",
    );
  }
  return LocalShell(environment: environment, driver: driver);
}

/// What the next command runs under: the picked Linux where it is installed
/// and this build carries proot, else the machine itself. Synchronous because
/// it is asked before every command.
///
/// On the machine itself, a rootfs-isolated built-in project's bin directory
/// is prefixed onto `PATH`; a user-set `PATH` in the command environment still
/// wins over it.
ShellDriver? platformDriver({
  required String defaultSkillsBundledDir,
  required String defaultUserSkillsDir,
  String? projectSkillsBundledDir,
  String? projectUserSkillsDir,
  Toolset? tools,
  Proot? proot,
  RootfsStore? store,
  String? rootfsId,
  String? abi,
  String? project,
  AppConfig? config,
  String? byteRepairBinDir,

  /// The login shell's PATH, captured once per run by `main.dart`: the
  /// driver is resolved synchronously, so the capture cannot happen here.
  String? loginPath,
}) {
  final rootfs = rootfsById(rootfsId);
  final baseDir =
      rootfs != null && store != null ? store.directoryOfSync(rootfs.id) : null;
  final isolated =
      project != null && builtinProjectOf(project)?.rootfsIsolation == true;
  if (rootfs != null && proot != null && baseDir != null) {
    // An isolated project runs its own rootfs copy so guest installs do not
    // leak between projects; the cached download is only the template.
    final dir = (isolated && config != null)
        ? _projectRootfsDir(config, project, rootfs.id) ?? baseDir
        : baseDir;
    // proot refuses a binding whose host path is missing ("can't sanitize
    // binding"), and a project's skill dirs exist only after a setup or a
    // first turn. The default project's two are always there.
    String? bindIfThere(String? path) =>
        path != null && Directory(path).existsSync() ? path : null;
    return prootDriver(
      proot: proot,
      rootfs: rootfs,
      rootfsDir: dir,
      defaultSkillsBundledDir: defaultSkillsBundledDir,
      defaultUserSkillsDir: defaultUserSkillsDir,
      projectSkillsBundledDir: bindIfThere(projectSkillsBundledDir),
      projectUserSkillsDir: bindIfThere(projectUserSkillsDir),
      abi: abi,
    );
  }
  return LocalShell.hostDriver(
      tools: tools,
      projectHome: Platform.isAndroid,
      environment: isolated && byteRepairBinDir != null
          ? {
              "PATH": "$byteRepairBinDir${LocalShell.listSeparator()}"
                  "${loginPath ?? Platform.environment["PATH"] ?? ""}",
            }
          : null,
      sandboxHelper: Platform.isLinux && config != null
          ? LandlockSandboxHelper(cacheDir: landlockCacheDir(config))
          : null,
      // A desktop launch's inherited PATH misses what the user's profile adds
      // (`~/.local/bin`); null leaves the inherited one standing.
      loginPath: loginPath);
}

/// Where the Landlock helper is compiled: the data directory rather than the
/// OS cache, so a cache clear does not cost the compile again.
String landlockCacheDir(AppConfig config) =>
    p.join(config.dataDir, "landlock");

/// The per-project rootfs copy, or null where it has not been made yet.
String? _projectRootfsDir(AppConfig config, String project, String rootfsId) {
  final dir = config.projectRootfsDir(project: project, rootfsId: rootfsId);
  return File(p.join(dir, ".complete")).existsSync() ? dir : null;
}

/// Which rootfs a download fetches: Android's ABI, "ios" on iOS (iSH emulates
/// x86, not the device's arm64), null on the desktops, which have no catalog.
Future<String?> deviceAbi() =>
    Platform.isIOS ? Future.value("ios") : BundledTools.abi();

/// What keeps the host shell's commands in. Linux's is the Landlock helper
/// [hostDriver] is built with; a phone's is the OS's own app sandbox.
Confinement hostConfinement() => Platform.isLinux
    ? Confinement.landlock
    : Platform.isAndroid || Platform.isIOS
        ? Confinement.appSandbox
        : Confinement.none;

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
    webViews:
        Platform.isAndroid || Platform.isIOS
            ? const MethodChannel("agent_chat/browser")
            : null,
  );
}

/// On iOS the unpack is iSH's fakefsify, not the system tar, which the exec
/// ban denies.
RootfsStore createRootfsStore(String cacheDir) =>
    Platform.isIOS
        ? FileRootfsStore(p.join(cacheDir, "rootfs"), tar: _ishFakefsify)
        : FileRootfsStore(p.join(cacheDir, "rootfs"));

/// Installs into the guest's `/usr/local/bin` on the phones (proot, iSH) and
/// the app's own bin directory on the desktops. A guest's `apk` installs in
/// minutes; a host install fetches a 240 MB ESBMC zip and wants the half hour.
ByteRepairStore createByteRepairStore(
    AppConfig config, String cacheDir, RootfsStore? rootfs) {
  final guest = Platform.isAndroid || Platform.isIOS;
  final project = ByteRepairProject().dir;
  return ByteRepairStore(
    config: config,
    project: project,
    workspace: config.projectWorkspaceDir(project: project),
    installDir: guest ? guestEsbmcInstallDir : byteRepairBinDir(cacheDir),
    installTimeout: guest ? guestInstallTimeout : hostInstallTimeout,
    rootfsStore: rootfs,
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
/// may empty. On a phone a rootfs must be picked, since the "Host" env has no
/// package manager (iOS's no shell) to stand the setup up again.
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

/// Lays out the tools this build ships for the device's ABI (Android only),
/// under the cache dir: rebuilt from the APK on demand, so a backup must not
/// carry its symlinks.
Future<Toolset?> installBundledTools(String cacheDir) async {
  if (!Platform.isAndroid) return null;
  final libDir = await BundledTools.nativeLibraryDir();
  if (libDir == null) return null;
  return BundledTools.install(root: p.join(cacheDir, "tools"), libDir: libDir);
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
        ? MlxEngine(FileLocalModelStore(p.join(cacheDir, "llm"), format: const MlxFormat()))
        : const NoLocalEngine();
  }
  if (!Platform.isAndroid && !Platform.isLinux) return const NoLocalEngine();
  final (String? libDir, String serverName) = Platform.isAndroid
      ? (await BundledTools.nativeLibraryDir(), "libllama-server.so")
      : (bundledLinuxLibDir(), "llama-server");
  if (libDir == null) return const NoLocalEngine(missingFromBuild: true);
  final server = p.join(libDir, serverName);
  if (!File(server).existsSync()) {
    return const NoLocalEngine(missingFromBuild: true);
  }
  final store = FileLocalModelStore(p.join(cacheDir, "llm"), format: const GgufFormat());
  final pool = LlamaServerPool(
    LlamaBinaries(server: server, libDir: libDir),
    store,
    slotSaveDir: _kvCacheDir(cacheDir),
    fitLayers: !Platform.isAndroid,
  );
  return LlamaEngine(pool, store, kvCache: FileKvCache(_kvCacheDir(cacheDir)));
}

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
        return AppleFmProbe(handshake["reason"] as String? ?? "other",
            mlx: handshake["mlx"] as bool? ?? false);
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

/// The server's `--slot-save-path` and [FileKvCache]'s directory: one join so
/// the two cannot disagree.
String _kvCacheDir(String cacheDir) => p.join(cacheDir, "kv-cache");

FileHandoff createFileHandoff() =>
    Platform.isAndroid ? AndroidFileHandoff() : const DesktopFileHandoff();

/// Android has no save dialog; a backup leaves through the share sheet.
BackupHandoff createBackupHandoff(FileHandoff handoff) =>
    Platform.isAndroid
        ? SharedBackup(handoff)
        : const FileSelectorBackup();

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
  final dir = await getApplicationDocumentsDirectory();
  return dir.path;
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
    final local = Platform.environment["LOCALAPPDATA"] ?? p.join(_home, "AppData", "Local");
    return p.join(local, _dirLeaf, "Cache");
  }
  return p.join((await getApplicationSupportDirectory()).path, "entoli");
}

/// Silero's detector ships inside the app, so its licence does too.
void registerVoiceLicences() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ["silero-vad"],
      await rootBundle.loadString("assets/models/silero-vad-LICENSE.txt"),
    );
  });
}

VoiceModelStore createVoiceModelStore(String cacheDir) =>
    FileVoiceModelStore(p.join(cacheDir, "models"));

/// record's own Linux implementation is parecord-only; ours falls back to
/// pw-record.
void registerRecorder() {
  if (Platform.isLinux) RecordPlatform.instance = LinuxRecorder();
}

/// sherpa-onnx on the desktops; Android and macOS also have their system
/// engines (see [AndroidVoice], [MacosVoice]); iOS has Apple's alone (see
/// [IosVoice]).
Voice createVoice(VoiceModelStore store, String cacheDir) {
  if (Platform.isAndroid) return AndroidVoice(store, cacheDir);
  if (Platform.isIOS) return const IosVoice();
  if (Platform.isMacOS) return MacosVoice(store, cacheDir);
  return SherpaVoice(store, cacheDir);
}

/// The process's environment. The Dart VM's iOS build leaves
/// `Platform.environment` empty, so a launch variable never reached a
/// provider's `apiKeyEnv` there; libc's `getenv` reads the real one.
String? processEnv(String name) =>
    Platform.isIOS ? _getenv(name) : Platform.environment[name];

final _libcGetenv = DynamicLibrary.process().lookupFunction<
    Pointer<Utf8> Function(Pointer<Utf8>),
    Pointer<Utf8> Function(Pointer<Utf8>)>("getenv");

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

/// The user's login shell's PATH, or null to keep the inherited one. Only
/// bash and zsh are asked, their profile syntax being known; a profile that
/// prints anything else is why the last non-empty line is read.
Future<String?> captureLoginPath() async {
  final home = LocalShell.machineHomeDir();
  final login = Platform.environment["SHELL"];
  if (home == null || login == null) return null;
  if (!(login.endsWith("/bash") || login == "bash" || login.endsWith("/zsh"))) {
    return null;
  }
  if (!File(login).existsSync()) return null;
  try {
    final process = await Process.start(login, ["-l", "-c", r'echo "$PATH"'],
        environment: {"HOME": home, "PATH": "/usr/bin:/bin"},
        includeParentEnvironment: false);
    final stdout = process.stdout.transform(systemEncoding.decoder).join();
    unawaited(process.stderr.drain<void>());
    final int code;
    try {
      code = await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // A profile that waits on input would otherwise be left running.
      process.kill(ProcessSignal.sigkill);
      return null;
    }
    if (code != 0) return null;
    final lines = (await stdout)
        .split("\n")
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    final path = lines.last;
    return path.contains("/") ? path : null;
  } on Exception {
    return null;
  }
}

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

/// iOS's rootfs unpack: iSH's `fakefsify` in-process (iOS denies a child
/// process for `tar`). The FFI call blocks, so it runs on its own isolate.
Future<ProcessResult> _ishFakefsify(String archive, String into) =>
    Isolate.run(() {
    final fn = ishFakefsifyFn;
    if (fn == null) {
      return ProcessResult(
          1, 1, "", "iSH fakefsify is not linked into this build.");
    }
    final archivePtr = archive.toNativeUtf8();
    final intoPtr = into.toNativeUtf8();
    try {
      final rc = fn(archivePtr, intoPtr);
      return rc == 0
          ? ProcessResult(0, 0, "", "")
          : ProcessResult(1, rc, "", "fakefsify failed (errno $rc)");
    } finally {
      malloc.free(archivePtr);
      malloc.free(intoPtr);
    }
  });

/// The app's read-only directories, one manager per path. See
/// `core/read_only_dirs.dart`.
final readOnlyDirs = ReadOnlyDirs(setTreeWritable);

/// Deletes a tree that may hold proot's mode-0000 bind stubs, which a plain
/// recursive delete cannot list. The restore clear needs it: the stubs sit
/// deep inside `projects/<project>/rootfs/`.
Future<void> deleteTree(String path) async {
  // removeTree's own `chmod` is a process, which iOS refuses, and Windows'
  // read-only attribute is not a mode at all; elsewhere it unlocks the tree
  // itself, and a second walk would be one more pass over a whole rootfs.
  if (Platform.isIOS || Platform.isWindows) {
    await setTreeWritable([path], writable: true);
  }
  final err = await removeTree(path);
  if (err != null) throw Exception("could not delete $path: $err");
}
