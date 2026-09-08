import "dart:io";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart" show rootBundle;
import "package:record_platform_interface/record_platform_interface.dart"
    show RecordPlatform;
import "package:fs_shim/fs.dart" hide File, Directory;
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

import "../../../data/backup_handoff.dart";
import "../../../data/local/android_assistant_launch.dart";
import "../../../data/local/android_device_name.dart";
import "../../../data/local/android_file_handoff.dart";
import "../../../data/local/android_reminder_alarms.dart";
import "../../../data/local/bundled_tools.dart";
import "../../../data/local/byte_repair_store.dart";
import "../../../data/local/file_byte_repair_store.dart";
import "../../../data/local/file_secret_store.dart";
import "../../../data/builtin/llm/local_kv_cache.dart";
import "../../../data/local/file_kv_cache.dart";
import "../../../data/local/file_local_model_store.dart";
import "../../../data/local/file_rootfs_store.dart";
import "../../../data/local/llama_server.dart";
import "../../../data/local/proot.dart";
import "../../../data/local/shared_backup.dart";
import "../../../data/local/tree_ops.dart";
import "../../../data/local/desktop_file_handoff.dart";
import "../../../data/local/linux_reminder_alarms.dart";
import "../../../data/builtin/duckduckgo_search.dart";
import "../../../data/builtin/local_shell.dart";
import "../../../data/voice/android_voice.dart";
import "../../../data/voice/file_voice_model_store.dart";
import "../../../data/voice/sherpa_voice.dart";
import "../../../domain/assistant_launch.dart";
import "../../../domain/backup_handoff.dart";
import "../../../domain/builtin_project.dart";
import "../../../domain/file_handoff.dart";
import "../../../domain/local_llm.dart";
import "../../../domain/local_model_store.dart";
import "../../../domain/reminder_alarms.dart";
import "../../../domain/rootfs.dart";
import "../../../domain/rootfs_store.dart";
import "../../../domain/secret_store.dart";
import "../../../domain/shell.dart";
import "../../../domain/sync/lan_signaling.dart";
import "../../../domain/voice.dart";
import "../../../domain/voice_model_store.dart";
import "../../../domain/web_search.dart";
import "../../config.dart";
import "keyring_secret_store.dart";
import "linux_recorder.dart";
import "signaling_server.dart";

Shell platformShell({
  required Map<String, String> Function() environment,
  required ShellDriver? Function({String? project}) driver,
}) =>
    LocalShell(environment: environment, driver: driver);

/// What the next command runs under: the Linux the settings page picked,
/// where it is installed, or the machine itself where there is no pick, or
/// the pick's files have gone, or this build carries no proot. Answered
/// synchronously because it is asked before every command.
///
/// On the machine itself, a rootfs-isolated built-in project's bin directory
/// rides in as a `PATH` prefix: the tools its setup fetched are its
/// environment, not every project's, the way its rootfs copy is. A user-set
/// `PATH` in the command environment still wins over it.
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
}) {
  final rootfs = rootfsById(rootfsId);
  final baseDir =
      rootfs != null && store != null ? store.directoryOfSync(rootfs.id) : null;
  // The isolation fact both branches ask: a rootfs-isolated built-in gets its
  // own environment, the guest copy inside a proot and the bin directory on
  // the host's PATH, rather than everything every project runs under.
  final isolated =
      project != null && builtinProjectOf(project)?.rootfsIsolation == true;
  if (rootfs != null && proot != null && baseDir != null) {
    // An isolated built-in project gets its own rootfs instance under its data
    // directory, so packages installed inside the guest do not leak between
    // projects. The base download in cache is the template; the project's copy
    // is its living filesystem.
    final dir = (isolated && config != null)
        ? _projectRootfsDir(config, project, rootfs.id) ?? baseDir
        : baseDir;
    return prootDriver(
      proot: proot,
      rootfs: rootfs,
      rootfsDir: dir,
      defaultSkillsBundledDir: defaultSkillsBundledDir,
      defaultUserSkillsDir: defaultUserSkillsDir,
      projectSkillsBundledDir: projectSkillsBundledDir,
      projectUserSkillsDir: projectUserSkillsDir,
      abi: abi,
    );
  }
  return LocalShell.hostDriver(
      tools: tools,
      projectHome: Platform.isAndroid,
      environment: isolated && byteRepairBinDir != null
          ? {
              "PATH":
                  "$byteRepairBinDir:${Platform.environment["PATH"] ?? ""}"
            }
          : null);
}

/// The per-project rootfs directory, or null where the copy has not been
/// created yet. Lives under the project's data directory, beside its workspace
/// and memory, so a backup carries it and a cache clear does not lose it.
String? _projectRootfsDir(AppConfig config, String project, String rootfsId) {
  final dir = config.projectRootfsDir(project: project, rootfsId: rootfsId);
  return File(p.join(dir, ".complete")).existsSync() ? dir : null;
}

/// Which architecture this install is for, which decides the rootfs a download
/// fetches. Null off Android.
Future<String?> platformAbi() => BundledTools.abi();

/// `assets/version.json` is a declared asset; the `assets/` prefix is part of
/// the key, not just the on-disk path.
Future<String?> platformVersionJson() async {
  try {
    return await rootBundle.loadString("assets/version.json");
  } catch (_) {
    return null;
  }
}

/// Where a downloaded Linux is kept: beside the voice models, outside the data
/// directory, and for the same reasons — see [RootfsStore].
RootfsStore platformRootfsStore(String cacheDir) =>
    FileRootfsStore(p.join(cacheDir, "rootfs"));

/// The Byte Repair store, which installs the tooling — into the project's
/// rootfs copy on Android, the app's own bin directory on the desktop —
/// and reports on it. [project] and [workspace] are named by the caller so
/// both sides of the conditional import agree on what the store is for.
///
/// Where the fetched tools land follows the shell they will run under: a
/// guest's `/usr/local/bin` where a rootfs can run (Android), the bin
/// directory [platformByteRepairBinDir] names elsewhere — Linux being the
/// desktop this app targets, and the only one whose host shell runs setup.
ByteRepairStore platformByteRepairStore(
  AppConfig config,
  String project,
  String workspace,
  String cacheDir,
  RootfsStore? rootfs,
) =>
    FileByteRepairStore(
      config: config,
      project: project,
      workspace: workspace,
      installDir:
          Platform.isAndroid ? guestEsbmcInstallDir : platformByteRepairBinDir(cacheDir)!,
      // A guest's apk is a local package manager; the host fetches a 240 MB
      // ESBMC release zip over the network.
      installTimeout: Platform.isAndroid
          ? const Duration(minutes: 10)
          : const Duration(minutes: 30),
      rootfsStore: rootfs,
    );

/// The bin directory a rootfs-isolated project's turns find the fetched tools
/// on, or null where there is nothing to inject — a guest reaches its own
/// `/usr/local/bin` without help, and every platform but Linux has no host
/// install to point at. The one composition of the path: the store's
/// `installDir` is derived from this, so the store that fills the directory
/// and the driver that injects it cannot disagree.
String? platformByteRepairBinDir(String cacheDir) =>
    Platform.isLinux ? p.join(cacheDir, "byte-repair", "bin") : null;

/// Whether a project's `.setup-complete` marker is there. Synchronous because
/// the chat page asks it in a build.
///
/// On the host the marker alone is not enough: the tools live in a cache
/// directory the OS may empty, so the binary the gate stands for has to be
/// there too. A cache clear between setups then leaves the chat page gated —
/// honestly, since nothing is on PATH — and Run Setup repairs it. Inside a
/// guest the marker is enough, since the rootfs copy it was written after is
/// under the data directory a backup carries.
bool platformSetupComplete(AppConfig config, String? project,
    {String? byteRepairBinDir}) {
  if (!File(config.setupCompleteFile(project: project)).existsSync()) {
    return false;
  }
  if (byteRepairBinDir == null) return true;
  return File(p.join(byteRepairBinDir, "esbmc")).existsSync();
}

/// Lay out whatever this build ships for the device's ABI, under [cacheDir]
/// rather than the data directory: it is rebuilt from the APK on demand, so a
/// backup carrying a tree of symlinks into an install that no longer exists
/// would be worse than useless.
///
/// Null where nothing is bundled — every platform but Android, and an Android
/// whose ABI this build has no tools for.
Future<Toolset?> platformInstallTools(String cacheDir) async {
  if (!Platform.isAndroid) return null;
  final libDir = await BundledTools.nativeLibraryDir();
  if (libDir == null) return null;
  return BundledTools.install(root: p.join(cacheDir, "tools"), libDir: libDir);
}

WebSearch platformWebSearch() => DuckDuckGoSearch();

/// Where a downloaded model is kept: beside the voice models and a downloaded
/// Linux, outside the data directory, and for the same reasons — see
/// [LocalModelStore].
LocalModelStore platformLocalModelStore(String cacheDir) =>
    FileLocalModelStore(p.join(cacheDir, "llm"));

/// llama.cpp's server, where this build carried one for the device's ABI.
///
/// **Android only, and that is a judgement rather than a limit.** The desktops
/// can already reach a model on the machine they are on — Ollama and LM Studio
/// are two of the presets in `llmProviderPresets`, and both are a better answer
/// than a second copy of llama.cpp inside this app. A phone has no such thing
/// to reach, which is the whole reason to carry one.
Future<LocalLlm> platformLocalLlm(LocalModelStore store, String cacheDir) async {
  if (!Platform.isAndroid) return const UnavailableLocalLlm();
  final libDir = await BundledTools.nativeLibraryDir();
  if (libDir == null) return const UnavailableLocalLlm();
  final server = File(p.join(libDir, "libllama-server.so"));
  if (!await server.exists()) return const UnavailableLocalLlm();
  return LlamaServerPool(
    LlamaBinaries(server: server.path, libDir: libDir),
    store,
    slotSaveDir: _kvCacheDir(cacheDir),
  );
}

/// The one directory the server's slot dumps and [FileKvCache] both read: the
/// pool launches the server with it as `--slot-save-path`, the cache reads and
/// evicts within it, so the two are built from the one join. Null off Android,
/// where there is no server to persist for.
String _kvCacheDir(String cacheDir) => p.join(cacheDir, "kv-cache");

LocalKvCache? platformLocalKvCache(String cacheDir, LocalLlm localLlm) =>
    localLlm.available ? FileKvCache(_kvCacheDir(cacheDir)) : null;

/// The one thing this side of the conditional import still has to choose at
/// runtime: a desktop and a phone share `dart:io` and agree on nothing else
/// here. Chosen once, so neither implementation carries a branch.
FileHandoff platformFileHandoff(FileSystem fs) =>
    Platform.isAndroid ? AndroidFileHandoff(fs) : const DesktopFileHandoff();

/// The same runtime choice again, and for a narrower reason: `file_selector`
/// has a save dialog on the desktops and none on Android, where a backup goes
/// out through the share sheet instead.
BackupHandoff platformBackupHandoff(FileSystem fs, FileHandoff handoff) =>
    Platform.isAndroid
        ? SharedBackup(fs, handoff)
        : const FileSelectorBackup();

/// The system's assistant gesture, which Android forwards as an `ACTION_ASSIST`
/// intent and no other platform here has. One answer per platform, chosen once
/// so neither implementation carries a branch.
AssistantLaunch platformAssistantLaunch() => Platform.isAndroid
    ? AndroidAssistantLaunch()
    : const UnavailableAssistantLaunch();

/// AlarmManager on Android; the session bus on Linux, whose notifications are
/// what a reminder's completion and a turn failure post through. Scheduling
/// rides the app's own timer where there is no clock to hand over — a reminder
/// missed while the app is closed is caught up at the next launch. macOS and
/// Windows have neither, and a browser's timers die with its tab.
Future<ReminderAlarms> platformReminderAlarms() async =>
    Platform.isAndroid
        ? AndroidReminderAlarms()
        : Platform.isLinux
            ? await connectLinuxReminderAlarms()
            : const UnavailableReminderAlarms();

FileSystem platformFileSystem() => fileSystemIo;

/// `$AGENT_CHAT_CONFIG` if set, else `~/.config/agent-chat` on desktop and
/// app-private storage on Android. A Linux debug build reads
/// `~/.config/agent-chat-debug`, so developing against an installed copy's
/// data is not possible by accident.
Future<String> platformDataDir() async {
  final override = Platform.environment["AGENT_CHAT_CONFIG"];
  return override ?? p.join(await _resolveBase(), _dirLeaf);
}

String get _dirLeaf => Platform.isLinux && kDebugMode ? "agent-chat-debug" : "agent-chat";

Future<String> _resolveBase() async {
  if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
    return p.join(_home, ".config");
  }
  final dir = await getApplicationDocumentsDirectory();
  return dir.path;
}

String get _home => LocalShell.machineHomeDir()!;

/// Where things that can be fetched again live — the voice models, and a
/// downloaded Linux beside them. `$AGENT_CHAT_CACHE` if set, else this platform's own cache
/// directory, by hand rather than through `path_provider` so that the name
/// beside `~/.config/agent-chat` is `~/.cache/agent-chat` — or, in a Linux
/// debug build, the `-debug` sibling of each.
///
/// **Android is the exception, and deliberately.** `getCacheDir()` is
/// evictable: the system empties it under storage pressure and the app's
/// settings offer a Clear Cache button that does the same. A model the user
/// chose to download is not something to lose that way, so it goes in the
/// support directory instead — still a sibling of the data directory, so a
/// backup does not carry it, but not something Android throws away.
Future<String> platformCacheDir() async {
  final override = Platform.environment["AGENT_CHAT_CACHE"];
  if (override != null) return override;
  if (Platform.isLinux) {
    final xdg = Platform.environment["XDG_CACHE_HOME"];
    return p.join(xdg ?? p.join(_home, ".cache"), _dirLeaf);
  }
  if (Platform.isMacOS) return p.join(_home, "Library", "Caches", "agent-chat");
  if (Platform.isWindows) {
    final local = Platform.environment["LOCALAPPDATA"] ?? p.join(_home, "AppData", "Local");
    return p.join(local, "agent-chat", "Cache");
  }
  return p.join((await getApplicationSupportDirectory()).path, "agent-chat");
}

/// Silero's detector ships inside the app, so its MIT licence ships with it —
/// the bargain `registerBundledFontLicences` makes for the bundled fonts, and
/// read lazily for the same reason. Here rather than in `main` because the
/// asset is `platforms:`-filtered out of the web build, where reading it would
/// throw and take Flutter's licence page down with it. The models the catalog
/// downloads are not here: they arrive at runtime carrying their own LICENSE
/// files, and are nothing the app distributes.
void platformRegisterVoiceLicences() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ["silero-vad"],
      await rootBundle.loadString("assets/models/silero-vad-LICENSE.txt"),
    );
  });
}

VoiceModelStore platformVoiceModelStore(String cacheDir) =>
    FileVoiceModelStore(p.join(cacheDir, "models"));

/// record's own Linux implementation is parecord-only; the recorder here
/// falls back to pw-record. Once, before any recorder exists.
void platformRegisterRecorder() {
  if (Platform.isLinux) RecordPlatform.instance = LinuxRecorder();
}

/// The desktops run sherpa-onnx, which is the only engine they have. Android
/// runs its own where their sentinel is picked and sherpa where a downloaded
/// model is, so it wants the store either way — see [AndroidVoice].
Voice platformVoice(VoiceModelStore store, String cacheDir) =>
    Platform.isAndroid ? AndroidVoice(store, cacheDir) : SherpaVoice(store, cacheDir);

/// Nothing to ask for: a directory on this machine is already as durable as
/// the app is.
Future<void> platformPersist() async {}

String? processEnv(String name) => Platform.environment[name];

/// This device's sync secrets: the desktop keyring where a Secret Service
/// answers, the plain file where none does. Android lands on the file too —
/// its app-private directory is already out of every other app's reach —
/// until its Keystore wiring lands.
SecretStore platformSecretStore(AppConfig config) =>
    KeyringSecretStore(FileSecretStore(config));

/// Desktops listen while pairing. The one-time code is armed per pairing
/// window by the hub, so the factory needs nothing from its caller.
LanSignaling? platformLanSignaling() => SignalingServer();

/// What this machine calls itself, for the sync device name.
///
/// On Android, `Platform.localHostname` is "localhost", so the system device
/// name is read through `AndroidDeviceName` instead — the name the user set in
/// system settings, falling back to the model. On Linux the hostname is the
/// machine's own and used directly. Guarded: a host with no resolvable name
/// throws rather than answering, and a pairing that failed over the machine's
/// name would be a strange way to lose.
Future<String?> platformHostname() async {
  if (Platform.isAndroid) return AndroidDeviceName.read();
  try {
    final name = Platform.localHostname.trim();
    return name.isEmpty ? null : name;
  } catch (_) {
    return null;
  }
}

/// Makes each path in [paths] read-only (chmod -R 555) so a weak model running
/// `bash` cannot unintentionally write to a skill directory. No-op on Windows
/// and macOS: the app targets Linux, Android, and Web, and the guard is only
/// meaningful where `chmod` exists. A determined model can `chmod u+w` its way
/// past this (the shell runs as the app's own uid), but that is a deliberate
/// bypass, not an unintentional edit — the approval regime disclaims that.
Future<void> platformChmodReadOnly(List<String> paths) async {
  if (!Platform.isLinux && !Platform.isAndroid) return;
  await Future.wait(paths.map((path) async {
    try {
      await Process.run("chmod", ["-R", "555", path]);
    } catch (_) {}
  }));
}

/// Toggles [path] writable for [action], then restores it to read-only. The
/// install and delete paths use this: they are the app's own writes, not the
/// model's, and they need the directory writable for the duration.
Future<T> platformWithWritableDir<T>(
    String path, Future<T> Function() action) async {
  if (Platform.isLinux || Platform.isAndroid) {
    try {
      await Process.run("chmod", ["-R", "u+w", path]);
    } catch (_) {}
  }
  try {
    return await action();
  } finally {
    if (Platform.isLinux || Platform.isAndroid) {
      try {
        await Process.run("chmod", ["-R", "555", path]);
      } catch (_) {}
    }
  }
}

/// Deletes a tree that may contain proot's mode-0000 bind stubs, which a plain
/// `Directory.delete(recursive: true)` cannot list and so dies on. Delegates to
/// `removeTree` (`tree_ops.dart`), the one place that knows about the stubs —
/// the same function the rootfs stores use to delete their own. Called by the
/// restore clear for every top-level directory in the data dir, because the
/// stubs sit deep inside `projects/<project>/rootfs/...` and a recursive delete
/// of the `projects/` entry dies on one. `dart:io`-only on purpose: the web has
/// no rootfs under the data directory and no stubs, so its side is a plain
/// recursive delete.
Future<void> platformDeleteTree(String path) async {
  final err = await removeTree(path);
  if (err != null) throw Exception("could not delete $path: $err");
}
