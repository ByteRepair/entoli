import "dart:js_interop";

import "package:fs_shim/fs.dart";
import "package:fs_shim/fs_browser.dart" show fileSystemWeb;
import "package:fs_shim/fs_idb.dart" show FileSystemIdbExt, FileSystemIdbOptions;
import "package:http/http.dart" as http;
import "package:web/web.dart" as web;

import "../../../data/backup_handoff.dart";
import "../../../data/local/apple_fm.dart";
import "../../../data/local/byte_repair_store.dart"
    show ByteRepairStore, UnavailableByteRepairStore;
import "../../../data/local/file_secret_store.dart";
import "../../../data/local/local_engine.dart";
import "../../../data/web/web_file_handoff.dart";
import "../../../domain/agent_browser.dart";
import "../../../domain/app_update.dart";
import "../../../domain/assistant_launch.dart";
import "../../../domain/confinement.dart";
import "../../../domain/backup_handoff.dart";
import "../../../domain/file_handoff.dart";
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
import "../../read_only_dirs.dart";
import "signaling.dart";

Shell platformShell({
  required Map<String, String> Function() environment,
  required ShellDriver? Function() driver,
  String? dataDir,
  RootfsStore? rootfsStore,
  String? Function()? rootfsId,
}) =>
    const UnavailableShell();

Future<Toolset?> installBundledTools(String cacheDir) async => null;

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

/// A page cannot drive another browser.
AgentBrowser createAgentBrowser(AppConfig config, String cacheDir) =>
    const UnavailableAgentBrowser();

/// A page runs no commands, so nothing keeps them in.
Confinement hostConfinement() => Confinement.none;

/// The site carries the newest build already; a reload is the update.
AppUpdateHost createAppUpdateHost(String cacheDir) =>
    const UnavailableAppUpdateHost();

Future<String?> deviceAbi() async => null;

/// A web build writes `version.json` beside `index.html` rather than under
/// `assets/`, so it is fetched rather than read through `rootBundle`.
Future<String?> platformVersionJson() async {
  try {
    return (await http.get(Uri.base.resolve("version.json"))).body;
  } catch (_) {
    return null;
  }
}

RootfsStore createRootfsStore(String cacheDir) => const UnavailableRootfsStore();

ByteRepairStore platformByteRepairStore(
  AppConfig config,
  String project,
  String workspace,
  String cacheDir,
  RootfsStore? rootfs,
) =>
    UnavailableByteRepairStore(
        config: config, project: project, workspace: workspace);

String? byteRepairBinDir(String cacheDir) => null;

/// Nothing could write the marker here, so nothing is gated by it.
bool setupComplete(AppConfig config, String? project, String? binDir) => true;

WebSearch platformWebSearch() => const UnavailableWebSearch();

Future<LocalEngine> createLocalEngine(String cacheDir) async => const NoLocalEngine();

Future<AppleFm?> createAppleFm() async => null;

/// Nominal: nothing here fetches a model.
Future<String> cacheDir() async => "/entoli-cache";

void registerVoiceLicences() {}

void registerRecorder() {}

VoiceModelStore createVoiceModelStore(String cacheDir) =>
    const UnavailableVoiceModelStore();

/// See issue #58: the browser's own speech APIs are how this platform gets
/// voice mode, rather than sherpa's WebAssembly.
Voice createVoice(VoiceModelStore store, String cacheDir) =>
    const UnavailableVoice();

FileHandoff platformFileHandoff(FileSystem fs) => WebFileHandoff(fs);

/// `file_selector` on the web is an `<input type="file">` in and an anchor with
/// a `download` attribute out, which is what a browser has in place of a save
/// dialog.
BackupHandoff platformBackupHandoff(FileSystem fs, FileHandoff handoff) =>
    const FileSelectorBackup();

AssistantLaunch createAssistantLaunch() => const UnavailableAssistantLaunch();

Future<ReminderAlarms> createReminderAlarms() async =>
    const UnavailableReminderAlarms();

FileWatches createFileWatches() => const UnavailableFileWatches();

/// Paged, which the default is not: unpaged, `fs_shim` stores a file as one
/// value and an append reads the whole thing back to rewrite it, which is the
/// opposite of what `conv.jsonl` is for. Page size is per file and converted on
/// the first write, so nothing has to be migrated.
FileSystem createFileSystem() =>
    fileSystemWeb.withIdbOptions(options: FileSystemIdbOptions.pageDefault);

/// Nominal but load-bearing: the root every path, chats included, is under.
Future<String> dataDir() async => "/entoli";

/// Without this the origin's storage is evictable. A browser that refuses
/// leaves the data evictable and nothing else changed.
Future<void> persist() async {
  try {
    await web.window.navigator.storage.persist().toDart;
  } catch (_) {}
}

String? processEnv(String name) => null;

/// No keyring: origin-scoped IndexedDB is this platform's ceiling, and the
/// Sync page says so.
SecretStore createSecretStore(AppConfig config) =>
    FileSecretStore(config);

/// Nowhere to bind: see `signaling.dart`. A web device pairs as the joiner.
LanSignaling? createLanSignaling() => createWebLanSignaling();

/// `location.hostname` is the server the page came from, not this machine.
Future<String?> deviceHostname() async => null;

Future<String?> captureLoginPath() async => null;

/// IndexedDB has no permissions to set, so every write goes straight through.
final readOnlyDirs = ReadOnlyDirs.none();

/// No rootfs here, so no proot stubs: a plain recursive delete.
Future<void> deleteTree(String path) async {
  final fs = fileSystemWeb;
  if (await fs.isDirectory(path)) {
    await fs.directory(path).delete(recursive: true);
  }
}
