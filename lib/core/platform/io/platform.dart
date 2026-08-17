import "dart:io";

import "package:fs_shim/fs.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";

import "../../../data/local/android_file_handoff.dart";
import "../../../data/local/desktop_file_handoff.dart";
import "../../../data/builtin/duckduckgo_search.dart";
import "../../../data/builtin/local_shell.dart";
import "../../../domain/file_handoff.dart";
import "../../../domain/shell.dart";
import "../../../domain/web_search.dart";

Shell platformShell({required Map<String, String> Function() environment}) =>
    LocalShell(environment: environment);

WebSearch platformWebSearch() => DuckDuckGoSearch();

/// The one thing this side of the conditional import still has to choose at
/// runtime: a desktop and a phone share `dart:io` and agree on nothing else
/// here. Chosen once, so neither implementation carries a branch.
FileHandoff platformFileHandoff(FileSystem fs) =>
    Platform.isAndroid ? AndroidFileHandoff(fs) : const DesktopFileHandoff();

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

/// Nothing to ask for: a directory on this machine is already as durable as
/// the app is.
Future<void> platformPersist() async {}

String? processEnv(String name) => Platform.environment[name];
