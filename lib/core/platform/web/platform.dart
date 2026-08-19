import "dart:js_interop";

import "package:fs_shim/fs.dart";
import "package:fs_shim/fs_browser.dart" show fileSystemWeb;
import "package:fs_shim/fs_idb.dart" show FileSystemIdbExt, FileSystemIdbOptions;
import "package:web/web.dart" as web;

import "../../../data/backup_handoff.dart";
import "../../../data/web/web_file_handoff.dart";
import "../../../domain/backup_handoff.dart";
import "../../../domain/file_handoff.dart";
import "../../../domain/shell.dart";
import "../../../domain/voice.dart";
import "../../../domain/voice_model_store.dart";
import "../../../domain/web_search.dart";

Shell platformShell({required Map<String, String> Function() environment}) =>
    const UnavailableShell();

WebSearch platformWebSearch() => const UnavailableWebSearch();

/// Nominal, like [platformDataDir]: nothing here fetches a model, so nothing
/// needs somewhere to keep one.
Future<String> platformCacheDir() async => "/agent-chat-cache";

/// Nothing to register: the Silero asset is not in this build.
void platformRegisterVoiceLicences() {}

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

