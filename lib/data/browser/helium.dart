import "dart:async";
import "dart:ffi" show Abi;
import "dart:io";

import "package:archive/archive_io.dart" show extractFileToDisk;
import "package:http/http.dart" as http;
import "package:path/path.dart" as p;

import "../../domain/agent_browser.dart";
import "../../domain/download.dart";
import "../download.dart" show latestReleaseTag;

/// Which desktop a Helium release is fetched for. Each has a repository of its
/// own, and its asset names carry the version.
enum HeliumOs { linux, macos, windows }

HeliumOs? get _hostOs => Platform.isLinux
    ? HeliumOs.linux
    : Platform.isMacOS
        ? HeliumOs.macos
        : Platform.isWindows
            ? HeliumOs.windows
            : null;

bool get _arm =>
    Abi.current() == Abi.linuxArm64 ||
    Abi.current() == Abi.macosArm64 ||
    Abi.current() == Abi.windowsArm64;

String heliumRepo(HeliumOs os) => "imputnet/helium-${os.name}";

/// The asset a release of [version] ships for [os] on this architecture: the
/// AppImage on Linux, which runs where it is put, the disk image on macOS and
/// the portable zip on Windows. Named as the release names them.
String heliumAsset(HeliumOs os, String version, {required bool arm}) =>
    switch (os) {
      HeliumOs.linux => "helium-$version-${arm ? "arm64" : "x86_64"}.AppImage",
      HeliumOs.macos => "helium_${version}_${arm ? "arm64" : "x86_64"}-macos.dmg",
      HeliumOs.windows => "helium_${version}_${arm ? "arm64" : "x64"}-windows.zip",
    };

/// Helium, downloaded into `<cache>/browser/download/`. Installed whole into a
/// staging directory beside it and renamed over it, so a download that dies
/// leaves the last one working.
class HeliumDownload implements EmbeddedBrowser {
  HeliumDownload(this.browserDir, {http.Client Function()? client})
      : _client = client ?? http.Client.new;

  /// `<cache>/browser`.
  final String browserDir;
  final http.Client Function() _client;

  String get _dir => p.join(browserDir, "download");
  File get _versionFile => File(p.join(_dir, "version"));

  @override
  String? get installedVersion {
    try {
      final version = _versionFile.readAsStringSync().trim();
      return version.isEmpty || executable == null ? null : version;
    } on FileSystemException {
      return null;
    }
  }

  @override
  String? get executable => _executableIn(_dir);

  static String? _executableIn(String dir) {
    final String? path = switch (_hostOs) {
      HeliumOs.linux => p.join(dir, "helium.AppImage"),
      HeliumOs.macos => _appExecutable(dir),
      HeliumOs.windows => _windowsExecutable(dir),
      null => null,
    };
    return path != null && File(path).existsSync() ? path : null;
  }

  static String? _appExecutable(String dir) {
    final apps = Directory(dir).existsSync()
        ? [
            for (final entry in Directory(dir).listSync())
              if (entry is Directory && entry.path.endsWith(".app")) entry.path,
          ]
        : const <String>[];
    return apps.isEmpty ? null : macAppExecutable(apps.first);
  }

  /// The zip holds one directory with the browser in it, under a name that
  /// has changed between releases.
  static String? _windowsExecutable(String dir) {
    if (!Directory(dir).existsSync()) return null;
    for (final entry in Directory(dir).listSync(recursive: true)) {
      final name = p.basename(entry.path).toLowerCase();
      if (entry is File && (name == "helium.exe" || name == "chrome.exe")) {
        return entry.path;
      }
    }
    return null;
  }

  /// Read off the redirect `releases/latest` answers with, as the app's own
  /// update check does: no API, so no rate limit.
  @override
  Future<String> latestVersion() async {
    final os = _hostOs ?? (throw UnsupportedError("No Helium for this OS."));
    final client = _client();
    try {
      return await latestReleaseTag(client, heliumRepo(os));
    } finally {
      client.close();
    }
  }

  @override
  Stream<DownloadProgress> install() async* {
    final os = _hostOs ?? (throw UnsupportedError("No Helium for this OS."));
    final version = await latestVersion();
    final asset = heliumAsset(os, version, arm: _arm);
    final staging = p.join(browserDir, "staging-$pid");
    final archive = p.join(browserDir, "$pid-$asset");
    try {
      await _deleteIfThere(staging);
      await Directory(staging).create(recursive: true);
      yield* _download(
          "https://github.com/${heliumRepo(os)}/releases/download/$version/$asset",
          archive);
      yield const DownloadProgress(received: 0, total: 0, unpacking: true);
      switch (os) {
        case HeliumOs.linux:
          final image = p.join(staging, "helium.AppImage");
          await File(archive).rename(image);
          final mode = await Process.run("chmod", ["755", image]);
          if (mode.exitCode != 0) {
            throw ProcessException(
                "chmod", ["755", image], "${mode.stderr}", mode.exitCode);
          }
        case HeliumOs.macos:
          await _copyFromImage(archive, staging);
        case HeliumOs.windows:
          await extractFileToDisk(archive, staging);
      }
      if (_executableIn(staging) == null) {
        throw StateError("The Helium download holds no browser to run.");
      }
      await File(p.join(staging, "version")).writeAsString(version);
      await _deleteIfThere(_dir);
      await Directory(staging).rename(_dir);
    } finally {
      await _deleteIfThere(staging);
      try {
        await File(archive).delete();
      } on FileSystemException {
        // Renamed into place on Linux, or never written.
      }
    }
  }

  Stream<DownloadProgress> _download(String url, String to) async* {
    final client = _client();
    try {
      final response = await client.send(http.Request("GET", Uri.parse(url)));
      if (response.statusCode != 200) {
        throw HttpException("${response.statusCode} for $url");
      }
      final total = response.contentLength ?? 0;
      final sink = File(to).openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          yield DownloadProgress(received: received, total: total);
        }
      } finally {
        await sink.close();
      }
      // A stream that ends short of what it declared is the one truncation
      // that looks like success.
      if (total > 0 && received != total) {
        throw HttpException("The download arrived at $received of $total bytes.");
      }
    } finally {
      client.close();
    }
  }

  /// Mount the image, copy the one app out of it, detach.
  Future<void> _copyFromImage(String dmg, String into) async {
    final mount = p.join(browserDir, "mount-$pid");
    await Directory(mount).create(recursive: true);
    final attach = await Process.run("hdiutil", [
      "attach", "-nobrowse", "-readonly", "-noautoopen",
      "-mountpoint", mount, dmg,
    ]);
    if (attach.exitCode != 0) {
      throw ProcessException(
          "hdiutil", ["attach", dmg], "${attach.stderr}", attach.exitCode);
    }
    try {
      final apps = [
        for (final entry in Directory(mount).listSync())
          if (entry is Directory && entry.path.endsWith(".app")) entry.path,
      ];
      if (apps.length != 1) {
        throw StateError("The Helium image holds ${apps.length} apps.");
      }
      final target = p.join(into, p.basename(apps.single));
      final copy = await Process.run("ditto", [apps.single, target]);
      if (copy.exitCode != 0) {
        throw ProcessException(
            "ditto", [apps.single, target], "${copy.stderr}", copy.exitCode);
      }
    } finally {
      await Process.run("hdiutil", ["detach", "-quiet", "-force", mount]);
      try {
        await Directory(mount).delete();
      } on FileSystemException {
        // Still mounted; the next install makes another.
      }
    }
  }

  @override
  Future<void> remove() => _deleteIfThere(_dir);

  static Future<void> _deleteIfThere(String path) async {
    final dir = Directory(path);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

/// The binary a macOS `.app` runs: `CFBundleExecutable` in its `Info.plist`,
/// else the one file in `Contents/MacOS`.
String? macAppExecutable(String app) {
  final macos = p.join(app, "Contents", "MacOS");
  try {
    final plist =
        File(p.join(app, "Contents", "Info.plist")).readAsStringSync();
    final name = RegExp(
            r"<key>CFBundleExecutable</key>\s*<string>([^<]+)</string>")
        .firstMatch(plist)
        ?.group(1);
    if (name != null && File(p.join(macos, name)).existsSync()) {
      return p.join(macos, name);
    }
  } catch (_) {
    // A binary plist, or none: fall through to the directory.
  }
  final files = Directory(macos).existsSync()
      ? Directory(macos).listSync().whereType<File>().toList()
      : const <File>[];
  return files.length == 1 ? files.single.path : null;
}
