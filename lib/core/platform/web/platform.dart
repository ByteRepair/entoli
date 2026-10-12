import "dart:js_interop";

import "package:fs_shim/fs.dart";
import "package:fs_shim/fs_browser.dart" show fileSystemWeb;
import "package:fs_shim/fs_idb.dart" show FileSystemIdbExt, FileSystemIdbOptions;
import "package:http/http.dart" as http;
import "package:web/web.dart" as web;

import "../../../data/backup_handoff.dart";
import "../../../data/builtin/llm/local_kv_cache.dart";
import "../../../data/local/byte_repair_store.dart"
    show ByteRepairStore, UnavailableByteRepairStore;
import "../../../data/local/file_secret_store.dart";
import "../../../data/web/web_file_handoff.dart";
import "../../../domain/app_update.dart";
import "../../../domain/assistant_launch.dart";
import "../../../domain/backup_handoff.dart";
import "../../../domain/file_handoff.dart";
import "../../../domain/local_llm.dart";
import "../../../domain/local_model_store.dart";
import "../../../domain/file_watches.dart";
import "../../../domain/reminder_alarms.dart";
import "../../../domain/rootfs_store.dart";
import "../../../domain/secret_store.dart";
import "../../../domain/shell.dart";
import "../../../domain/sync/lan_signaling.dart";
import "../../../domain/voice.dart";
import "../../../domain/voice_model_store.dart";
import "../../../domain/web_search.dart";
import "../../config.dart";
import "signaling.dart";

Shell platformShell({
  required Map<String, String> Function() environment,
  required ShellDriver? Function() driver,
  String? dataDir,
  RootfsStore? rootfsStore,
  String? Function()? rootfsId,
}) =>
    const UnavailableShell();

Future<Toolset?> platformInstallTools(String cacheDir) async => null;

/// A browser cannot run a command at all, so there is nothing for a Linux to
/// be run under. The [project], [config] and [byteRepairBinDir] parameters
/// are unused here: the io side resolves a per-project rootfs instance and a
/// per-project bin directory from them.
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
  String? loginPath,
}) =>
    null;

/// The app replacing itself from the latest release. A browser is not one of
/// the platforms that can: the site carries the newest build already, and a
/// reload of it is the whole of what an update means here.
AppUpdateHost platformUpdateHost(String cacheDir) =>
    const UnavailableAppUpdateHost();

Future<String?> platformAbi() async => null;

/// A web build writes `version.json` beside `index.html` rather than under
/// `assets/`, so it is fetched rather than read through `rootBundle`.
Future<String?> platformVersionJson() async {
  try {
    return (await http.get(Uri.base.resolve("version.json"))).body;
  } catch (_) {
    return null;
  }
}

RootfsStore platformRootfsStore(String cacheDir) => const UnavailableRootfsStore();

/// Nothing to copy a rootfs onto and no shell to run an install script in:
/// every operation answers with an error from the store itself.
ByteRepairStore platformByteRepairStore(
  AppConfig config,
  String project,
  String workspace,
  String cacheDir,
  RootfsStore? rootfs,
) =>
    UnavailableByteRepairStore(
        config: config, project: project, workspace: workspace);

/// No bin directory: there is no shell to inject one into.
String? platformByteRepairBinDir(String cacheDir) => null;

/// True: there is no marker to read and nothing that could write one, so a
/// project that requires setup never gates a chat here.
bool platformSetupComplete(AppConfig config, String? project,
        {String? byteRepairBinDir}) =>
    true;

WebSearch platformWebSearch() => const UnavailableWebSearch();

/// Nowhere to put a gigabyte of weights, and nothing that could run them.
LocalModelStore platformLocalModelStore(String cacheDir) =>
    const UnavailableLocalModelStore();

Future<LocalLlm> platformLocalLlm(LocalModelStore store, String cacheDir) async =>
    const UnavailableLocalLlm();

/// No server, so nothing to persist a KV cache for.
LocalKvCache? platformLocalKvCache(String cacheDir, LocalLlm localLlm) => null;

/// Nominal, like [platformDataDir]: nothing here fetches a model, so nothing
/// needs somewhere to keep one.
Future<String> platformCacheDir() async => "/agent-chat-cache";

/// Nothing to register: the Silero asset is not in this build.
void platformRegisterVoiceLicences() {}

/// No recorder of the platform's own: voice mode runs nothing here.
void platformRegisterRecorder() {}

VoiceModelStore platformVoiceModelStore(String cacheDir) =>
    const UnavailableVoiceModelStore();

/// See issue #58: the browser's own speech APIs are how this platform gets
/// voice mode, rather than sherpa's WebAssembly.
Voice platformVoice(VoiceModelStore store, String cacheDir) =>
    const UnavailableVoice();

FileHandoff platformFileHandoff(FileSystem fs) => WebFileHandoff(fs);

/// `file_selector` on the web is an `<input type="file">` in and an anchor with
/// a `download` attribute out, which is what a browser has in place of a save
/// dialog.
BackupHandoff platformBackupHandoff(FileSystem fs, FileHandoff handoff) =>
    const FileSelectorBackup();

/// A browser has no system assistant gesture. The stream never fires, so the
/// launch handler is inert — the same answer the desktop stub gives.
AssistantLaunch platformAssistantLaunch() => const UnavailableAssistantLaunch();

/// A browser cannot be woken, so nothing is ever due by the system's say-so,
/// and it has no session bus to post what a reminder did through either.
Future<ReminderAlarms> platformReminderAlarms() async =>
    const UnavailableReminderAlarms();

/// An IndexedDB file system has no inotify to carry, and nothing a browser
/// runs is in the way of a change the app itself made — the app would have
/// to hear its own writes, which the trigger's own edit is.
FileWatches platformFileWatches() => const UnavailableFileWatches();

/// IndexedDB, through the same `FileSystem` the rest of the app is written
/// against. The layout under [platformDataDir] is the one on disk elsewhere.
///
/// Paged, which the default is not: unpaged, `fs_shim` stores a file as one
/// value and an append reads the whole thing back to rewrite it, which is the
/// opposite of what `conv.jsonl` is for. Page size is per file and converted on
/// the first write, so nothing has to be migrated.
FileSystem platformFileSystem() =>
    fileSystemWeb.withIdbOptions(options: FileSystemIdbOptions.pageDefault);

/// Nominal on a platform with no filesystem of its own, but not arbitrary: it
/// is the root every path is resolved under, and what the chats are stored
/// beneath.
Future<String> platformDataDir() async => "/agent-chat";

/// Ask the browser to keep what we wrote. Without this the origin's storage is
/// evictable, and a chat can be gone on the next visit because something else
/// wanted the space. A browser that refuses (or does not implement it) leaves
/// the app working exactly as it did — the data is just evictable again.
Future<void> platformPersist() async {
  try {
    await web.window.navigator.storage.persist().toDart;
  } catch (_) {}
}

String? processEnv(String name) => null;

/// A browser has no keyring to ask. The file under the data directory —
/// origin-scoped IndexedDB — is the ceiling this platform has; the Sync page
/// says so rather than pretending otherwise.
SecretStore platformSecretStore(AppConfig config) =>
    FileSecretStore(config);

/// Nowhere to bind: see `signaling.dart`. A web device pairs as the joiner.
LanSignaling? platformLanSignaling() => createWebLanSignaling();

/// A browser has no hostname of its own to give. `location.hostname` is the
/// server the page came from, which is a different machine's name entirely.
Future<String?> platformHostname() async => null;

/// And no login shell: there is no shell behind any of a browser's commands,
/// which is the whole of what a browser's shell driver is.
Future<String?> platformCaptureLoginPath() async => null;

/// No-op: a browser has no `chmod`, and no `bash` to guard against. The file
/// tools' `safeRelativePath` already prevents reaching skill dirs.
Future<void> platformChmodReadOnly(List<String> paths) async {}

/// No-op: a browser has no `chmod`, so there is no lock to release either.
Future<void> platformChmodWritable(List<String> paths) async {}

/// No-op on the web: there is nothing to toggle. The action runs directly.
Future<T> platformWithWritableDir<T>(
        String path, Future<T> Function() action) async =>
    await action();

/// The web has no rootfs under the data directory (the Byte Repair store is
/// `Unavailable`), so there are no proot mode-0000 stubs to `chmod` past — a
/// plain recursive delete is all the restore clear needs here. The signature
/// matches the io side so `restoreBackup` calls one seam.
Future<void> platformDeleteTree(String path) async {
  final fs = fileSystemWeb;
  if (await fs.isDirectory(path)) {
    await fs.directory(path).delete(recursive: true);
  }
}
