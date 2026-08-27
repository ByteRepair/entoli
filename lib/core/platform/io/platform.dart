import "dart:io";

import "package:ffi/ffi.dart";
import "package:flutter/foundation.dart";
import "package:flutter/services.dart" show rootBundle;
import "package:fs_shim/fs.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

import "../../../data/backup_handoff.dart";
import "../../../data/local/android_assistant_launch.dart";
import "../../../data/local/android_file_handoff.dart";
import "../../../data/local/android_reminder_alarms.dart";
import "../../../data/local/bundled_tools.dart";
import "../../../data/local/file_secret_store.dart";
import "../../../data/builtin/llm/local_kv_cache.dart";
import "../../../data/local/file_kv_cache.dart";
import "../../../data/local/file_local_model_store.dart";
import "../../../data/local/file_rootfs_store.dart";
import "../../../data/local/ish_ffi.dart";
import "../../../data/local/ish_shell.dart";
import "../../../data/local/llama_server.dart";
import "../../../data/local/proot.dart";
import "../../../data/local/shared_backup.dart";
import "../../../data/local/desktop_file_handoff.dart";
import "../../../data/builtin/duckduckgo_search.dart";
import "../../../data/builtin/local_shell.dart";
import "../../../data/voice/android_voice.dart";
import "../../../data/voice/file_voice_model_store.dart";
import "../../../data/voice/sherpa_voice.dart";
import "../../../domain/assistant_launch.dart";
import "../../../domain/backup_handoff.dart";
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
import "signaling_server.dart";

Shell platformShell({
  required Map<String, String> Function() environment,
  required ShellDriver? Function() driver,
  String? dataDir,
  RootfsStore? rootfsStore,
  String? rootfsId,
}) {
  if (Platform.isIOS) {
    // iOS has no host shell and no proot — the driver callback (which picks
    // between the two on other platforms) is not exec-based here. IshShell
    // drives the emulator through FFI; it resolves the rootfs the way
    // platformDriver does, but without producing a ShellDriver, since there
    // is nothing to exec. See ios/CLAUDE.md.
    final rootfs = rootfsById(rootfsId);
    final dir = rootfs != null && rootfsStore != null
        ? rootfsStore.directoryOfSync(rootfs.id)
        : null;
    final installed = rootfs != null && dir != null;
    return IshShell(
      rootfsDir: dir ?? "",
      dataDir: dataDir ?? "",
      environment: environment,
      platformDescription: installed
          ? rootfs.describe("ios")
          : "iOS, with no Linux installed. Install one from the Terminal "
              "settings to run commands.",
    );
  }
  return LocalShell(environment: environment, driver: driver);
}

/// What the next command runs under: the Linux the settings page picked,
/// where it is installed, or the machine itself where there is no pick, or
/// the pick's files have gone, or this build carries no proot. Answered
/// synchronously because it is asked before every command.
ShellDriver? platformDriver({
  required String dataDir,
  Toolset? tools,
  Proot? proot,
  RootfsStore? store,
  String? rootfsId,
  String? abi,
}) {
  final rootfs = rootfsById(rootfsId);
  final dir =
      rootfs != null && store != null ? store.directoryOfSync(rootfs.id) : null;
  if (rootfs != null && proot != null && dir != null) {
    return prootDriver(
      proot: proot,
      rootfs: rootfs,
      rootfsDir: dir,
      dataDir: dataDir,
      abi: abi,
    );
  }
  return LocalShell.hostDriver(tools: tools);
}

/// Which architecture this install is for, which decides the rootfs a download
/// fetches. Null off Android and iOS — iOS has no Android ABI, but it has its
/// own rootfs key ("ios") since iSH emulates x86 and not the device's arm64.
Future<String?> platformAbi() =>
    Platform.isIOS ? Future.value("ios") : BundledTools.abi();

/// Here `version.json` is inside `flutter_assets`, so the bundle has it.
Future<String?> platformVersionJson() async {
  try {
    return await rootBundle.loadString("version.json");
  } catch (_) {
    return null;
  }
}

/// Where a downloaded Linux is kept: beside the voice models, outside the data
/// directory, and for the same reasons — see [RootfsStore]. On iOS the tar
/// callback is iSH's fakefsify, not the system tar (which the exec ban denies).
RootfsStore platformRootfsStore(String cacheDir) =>
    Platform.isIOS
        ? FileRootfsStore(p.join(cacheDir, "rootfs"), tar: _ishFakefsify)
        : FileRootfsStore(p.join(cacheDir, "rootfs"));

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

/// AlarmManager on Android, nothing anywhere else — the desktops have no
/// scheduler to hand over, and a browser's timers die with its tab.
ReminderAlarms platformReminderAlarms() => Platform.isAndroid
    ? AndroidReminderAlarms()
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

String get _home => Platform.environment["HOME"] ?? Platform.environment["USERPROFILE"]!;

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
/// the bargain `registerBundledFontLicences` makes for Roboto Mono, and read
/// lazily for the same reason. Here rather than in `main` because the asset is
/// `platforms:`-filtered out of the web build, where reading it would throw and
/// take Flutter's licence page down with it. The models the catalog downloads
/// are not here: they arrive at runtime carrying their own LICENSE files, and
/// are nothing the app distributes.
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

/// The desktops run sherpa-onnx, which is the only engine they have. Android
/// runs its own, and ships none of sherpa's native code at all — the `.so`
/// files are excluded at packaging in `android/app/build.gradle.kts`, so
/// constructing a [SherpaVoice] there would fail at the first FFI call.
Voice platformVoice(VoiceModelStore store, String cacheDir) =>
    Platform.isAndroid ? const AndroidVoice() : SherpaVoice(store, cacheDir);

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

/// What this machine calls itself, for the sync device name. Guarded: a host
/// with no resolvable name throws rather than answering, and a pairing that
/// failed over the machine's name would be a strange way to lose.
String? platformHostname() {
  try {
    final name = Platform.localHostname.trim();
    return name.isEmpty ? null : name;
  } catch (_) {
    return null;
  }
}

/// iOS's rootfs unpack: iSH's `fakefsify` in-process, not the system `tar`
/// (which iOS denies an app a child process to run). Converts the tarball into
/// the fakefs SQLite layout the emulator reads. Called through FFI on the
/// background isolate; `ishFakefsifyFn` is null off iOS, so this is never
/// reached on a desktop or a browser.
Future<ProcessResult> _ishFakefsify(String archive, String into) async {
  final fn = ishFakefsifyFn;
  if (fn == null) {
    return ProcessResult(
        1, 1, "", "iSH fakefsify is not linked into this build.");
  }
  final archivePtr = archive.toNativeUtf8();
  final intoPtr = into.toNativeUtf8();
  final rc = fn(archivePtr, intoPtr);
  calloc.free(archivePtr);
  calloc.free(intoPtr);
  if (rc == 0) return ProcessResult(0, 0, "", "");
  return ProcessResult(1, rc, "", "fakefsify failed (errno $rc)");
}
