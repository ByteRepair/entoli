import "dart:io";

import "package:flutter/foundation.dart";
import "package:flutter/services.dart" show rootBundle;
import "package:fs_shim/fs.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

import "../../../data/backup_handoff.dart";
import "../../../data/local/android_assistant_launch.dart";
import "../../../data/local/android_file_handoff.dart";
import "../../../data/local/shared_backup.dart";
import "../../../data/local/desktop_file_handoff.dart";
import "../../../data/builtin/duckduckgo_search.dart";
import "../../../data/builtin/local_shell.dart";
import "../../../data/voice/file_voice_model_store.dart";
import "../../../data/voice/sherpa_voice.dart";
import "../../../domain/assistant_launch.dart";
import "../../../domain/backup_handoff.dart";
import "../../../domain/file_handoff.dart";
import "../../../domain/shell.dart";
import "../../../domain/unavailable_assistant_launch.dart";
import "../../../domain/voice.dart";
import "../../../domain/voice_model_store.dart";
import "../../../domain/web_search.dart";

Shell platformShell({required Map<String, String> Function() environment}) =>
    LocalShell(environment: environment);

WebSearch platformWebSearch() => DuckDuckGoSearch();

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

FileSystem platformFileSystem() => fileSystemIo;

/// `$AGENT_CHAT_CONFIG` if set, else `~/.config/agent-chat` on desktop and
/// app-private storage on Android.
Future<String> platformDataDir() async {
  final override = Platform.environment["AGENT_CHAT_CONFIG"];
  return override ?? p.join(await _resolveBase(), "agent-chat");
}

Future<String> _resolveBase() async {
  if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
    return p.join(_home, ".config");
  }
  final dir = await getApplicationDocumentsDirectory();
  return dir.path;
}

String get _home => Platform.environment["HOME"] ?? Platform.environment["USERPROFILE"]!;

/// Where things that can be fetched again live — the voice models, and nothing
/// else so far. `$AGENT_CHAT_CACHE` if set, else this platform's own cache
/// directory, by hand rather than through `path_provider` so that the name
/// beside `~/.config/agent-chat` is `~/.cache/agent-chat`.
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
    return p.join(xdg ?? p.join(_home, ".cache"), "agent-chat");
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

Voice platformVoice(VoiceModelStore store, String cacheDir) =>
    SherpaVoice(store, cacheDir);

/// Nothing to ask for: a directory on this machine is already as durable as
/// the app is.
Future<void> platformPersist() async {}

String? processEnv(String name) => Platform.environment[name];
