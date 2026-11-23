import "dart:io";

import "package:entoli_core/model/log.dart";
import "package:entoli_core/model/migrations.dart";
import "package:file/local.dart";
import "package:flutter/foundation.dart";
import "package:path/path.dart" as p;
import "package:path_provider/path_provider.dart";
import "package:path_provider_foundation/path_provider_foundation.dart";

import "backup_exclusion.dart";

/// The App Group the Runner shares with its File Provider extension, which
/// reads the workspaces from the data directory inside it. See "The
/// workspaces in the Files app" in ios/AGENTS.md.
const iosAppGroup = "group.io.byterepair.entoli";

/// Where this platform keeps the app's data and its cache. [home] is the
/// machine user's home directory, which the desktops' answers are under.
AppDirectories appDirectories({required String? home}) =>
    AppDirectories._(home);

class AppDirectories {
  AppDirectories._(this._home);

  final String? _home;

  /// `~/.config/entoli` on desktop and app-private storage on the phones. A
  /// desktop debug build uses `entoli-debug`, so it never touches an
  /// installed copy's data; a phone's debug build is its own app, its
  /// storage already apart. Resolved once, since on iOS resolving it may
  /// move the directory.
  late final Future<String> data = _data();

  /// The platform's cache directory, named by hand so it pairs with
  /// `~/.config/entoli`.
  ///
  /// **Android uses the support directory, deliberately**: `getCacheDir()` is
  /// emptied under storage pressure and by Clear Cache, and a model the user
  /// chose to download is not something to lose that way.
  late final Future<String> cache = _cache();

  String get _leaf =>
      (Platform.isLinux || Platform.isMacOS || Platform.isWindows) && kDebugMode
      ? "entoli-debug"
      : "entoli";

  Future<String> _data() async => p.join(await _dataBase(), _leaf);

  Future<String> _dataBase() async {
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      return p.join(_home!, ".config");
    }
    if (Platform.isIOS) return _iosBase();
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  /// The App Group's container, once `relocateDataDir` has moved a data
  /// directory from before it out of Documents. Documents stays where the
  /// move fails, so the app still runs; the Files app then shows nothing
  /// until a launch where it lands.
  Future<String> _iosBase() async {
    final group = await PathProviderFoundation().getContainerPath(
      appGroupIdentifier: iosAppGroup,
    );
    // Every launch after the move ends here, with no need of Documents.
    if (group != null && Directory(p.join(group, _leaf)).existsSync()) {
      return group;
    }
    final documents = (await getApplicationDocumentsDirectory()).path;
    if (group == null) {
      logFailure("files", "no App Group container, data stays in Documents");
      return documents;
    }
    final moved = relocateDataDir(
      const LocalFileSystem(),
      from: p.join(documents, _leaf),
      to: p.join(group, _leaf),
    );
    return moved ? group : documents;
  }

  Future<String> _cache() async {
    if (Platform.isLinux) {
      final xdg = Platform.environment["XDG_CACHE_HOME"];
      return p.join(xdg ?? p.join(_home!, ".cache"), _leaf);
    }
    if (Platform.isMacOS) return p.join(_home!, "Library", "Caches", _leaf);
    if (Platform.isWindows) {
      final local =
          Platform.environment["LOCALAPPDATA"] ??
          p.join(_home!, "AppData", "Local");
      return p.join(local, _leaf, "Cache");
    }
    final dir = p.join((await getApplicationSupportDirectory()).path, "entoli");
    // iOS backs up Application Support, and Caches is purged under storage
    // pressure, which a downloaded model must survive. Apple's answer for
    // data that is refetchable yet kept is this, with the backup flag set.
    if (Platform.isIOS) {
      Directory(dir).createSync(recursive: true);
      if (!excludeFromBackup(dir)) {
        logFailure("files", "could not exclude the cache from backup");
      }
    }
    return dir;
  }
}
