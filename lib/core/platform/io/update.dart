import "dart:ffi";
import "dart:io";

import "package:ffi/ffi.dart";
import "package:flutter/foundation.dart"
    show kDebugMode, kProfileMode;
import "package:http/http.dart" as http;
import "package:path/path.dart" as p;

import "../../tls.dart";
import "../../log.dart";
import "../../../data/download.dart" show latestReleaseTag;
import "../../../domain/app_update.dart";

const _tag = "update";

/// How long the tag check waits before giving the network up. The download is
/// not given the same: an AppImage or an installer is a hundred megabytes on
/// a connection nobody is holding their breath for.
const _tagTimeout = Duration(seconds: 30);

/// What a check that was killed mid-flight leaves behind, and how long it
/// sits before the next one takes it away.
const _stale = Duration(days: 1);

/// The prefix the platform half stages under, on Linux beside the AppImage
/// and on macOS beside the bundle it will swap into.
const _stagingPrefix = ".entoli-";

/// The three desktops, replacing themselves from the release the tag names.
/// One class, because the check is the same on all of them — tag, compare,
/// download — and only what putting a build in place means differs:
///
/// - Linux: the AppImage file, renamed over the one this process is running
///   from. POSIX takes the name out from under a running binary; the old
///   inode keeps this process alive, the new one serves the next launch.
/// - macOS: the disk image, mounted for the app bundle inside it, which is
///   copied beside the running bundle and swapped in by one atomic rename.
/// - Windows: the installer, armed to run the moment this process exits —
///   a running exe cannot be renamed, and the install is the update.
///
/// The staged artifact is only ever put in place after the download has
/// arrived whole; a check that fails at any point takes its own staging back.
class DesktopUpdater implements AppUpdateHost {
  DesktopUpdater({
    required this.flavour,
    required this.cacheDir,

    /// The AppImage file this build runs from, or null where it does not —
    /// `flutter run` and an extracted bundle. Default: the `APPIMAGE`
    /// variable the AppImage runtime sets.
    String? appImage,

    /// The `.app` this build executes from, or null where it is not inside
    /// one. Default: walked up from the executable, which only an installed
    /// (or built) bundle sits at the end of.
    String? bundle,

    /// The installed `entoli.exe` this build runs from, or null where it is
    /// not the MSI's — a `flutter run`, a copied Release folder. Default:
    /// the executable, where it sits under Program Files\Entoli.
    String? installedExe,
    this.httpClient,

    /// The Windows half only: what starts the exit-armed installer. Default
    /// is a detached PowerShell waiting for this process to die.
    this.spawn,

    /// Whether to treat this run as a debug or profile build, which checks
    /// nothing. Null asks what this run is, which under `flutter test` is a
    /// debug build — so a test that wants the check to run passes `false`.
    this.debug,
  })  : appImage = appImage ?? Platform.environment["APPIMAGE"],
        bundle = bundle ?? _resolvedBundle(),
        installedExe = installedExe ??
            installedWindowsExe(
                Platform.resolvedExecutable, Platform.environment);

  final UpdateFlavour flavour;
  final String cacheDir;
  final String? appImage;
  final String? bundle;
  final String? installedExe;

  /// The client the tag check and the download ride, or null to make one per
  /// check and close it there — a client dropped open holds its socket.
  final http.Client? httpClient;

  /// What starts the exit-armed installer for [UpdateFlavour.windows], or
  /// null for the detached PowerShell.
  final Future<void> Function(String script)? spawn;

  /// Whether this run counts as a debug or profile build, and so checks
  /// nothing.
  final bool? debug;

  @override
  bool get available => true;

  @override
  Future<void> check({required String? version, required bool enabled}) async {
    if (!enabled) return logDetail(_tag, () => "off");
    // A debug or profile build has no release behind it to be newer than, and
    // a developer has better things than the build tree under them being
    // swapped.
    if (debug ?? (kDebugMode || kProfileMode)) {
      return logDetail(_tag, () => "debug build; not checked");
    }
    if (version == null) {
      return logDetail(_tag, () => "the running version is unknown");
    }
    // A trigger wake is a hidden session that exits when its turn is done,
    // not a launch to spend a download on.
    if (Platform.environment["ENTOLI_WAKE"] == "1") {
      return logDetail(_tag, () => "a wake session; not checked");
    }
    if (!await _located()) {
      return logDetail(_tag, () => "not running from a $flavourBuild");
    }
    // Leftovers first, before anything of this run's: a check that was killed
    // mid-flight left its staging behind, and nothing of a day old in these
    // places is anything running.
    await _dropStale();
    final client = httpClient ?? tlsClient();
    String? staged;
    try {
      final tag = await latestReleaseTag(client, updateRepo, timeout: _tagTimeout);
      if (!versionIsNewer(version, tag)) {
        return logDetail(_tag, () => "$version is current against $tag");
      }
      // Named here rather than inside the download, so a download that
      // stops short leaves the file the catch below knows to take back.
      staged = switch (flavour) {
        UpdateFlavour.linux => p.join(p.dirname(appImage!), _stagingName),
        UpdateFlavour.macos => _cacheStage(assetFor(flavour)),
        UpdateFlavour.windows => _cacheStage(assetFor(flavour)),
      };
      await _download(client, tag, staged);
      await switch (flavour) {
        UpdateFlavour.linux => _replaceAppImage(staged),
        UpdateFlavour.macos => _swapBundle(staged),
        UpdateFlavour.windows => _armInstaller(staged),
      };
      logDetail(_tag, () => "put $tag in place; the next start runs it");
    } catch (error) {
      // Nothing half-staged stays: a download that stopped short or a replace
      // that did not happen takes its own staging back.
      if (staged != null) await _discard(staged);
      logFailure(_tag, "updating to the latest release failed", error);
    } finally {
      client.close();
    }
  }

  /// Whether this build is anywhere it could be replaced from: Linux without
  /// an AppImage under it, macOS out of a plain bundle and Windows out of
  /// anything but the installed folder are checks that would run at nothing.
  Future<bool> _located() async => switch (flavour) {
        UpdateFlavour.linux => appImage != null,
        UpdateFlavour.macos => bundle != null && await _writableBeside(bundle!),
        UpdateFlavour.windows => installedExe != null,
      };

  /// Whether the swap could land: a translocated copy, a mounted image or a
  /// folder this user cannot write would otherwise fetch the whole image on
  /// every launch and fail at the end.
  Future<bool> _writableBeside(String bundle) async {
    if (bundle.contains("/AppTranslocation/")) return false;
    final probe = Directory(p.join(p.dirname(bundle), _stagingName));
    try {
      await probe.create();
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  String get flavourBuild => switch (flavour) {
        UpdateFlavour.linux => "AppImage",
        UpdateFlavour.macos => "installed bundle",
        UpdateFlavour.windows => "installed app",
      };

  /// The release asset, streamed onto [staged] — beside the AppImage it will
  /// rename over on Linux, one filesystem so the rename is atomic, and in the
  /// cache's updates directory on the other two.
  Future<void> _download(http.Client client, String tag, String staged) async {
    // The cache stage's directory, on the desktops that use it. Beside the
    // AppImage there is nothing to make: it exists because the app runs there.
    await Directory(p.dirname(staged)).create(recursive: true);
    final asset = assetFor(flavour);
    final url = assetDownloadUrl(tag, asset);
    final response = await client.send(http.Request("GET", Uri.parse(url)));
    if (response.statusCode != 200) {
      throw HttpException("${response.statusCode} for $asset");
    }
    final sink = File(staged).openWrite();
    var received = 0;
    try {
      await sink.addStream(response.stream.map((chunk) {
        received += chunk.length;
        return chunk;
      }));
    } finally {
      await sink.close();
    }
    // A stream that ends cleanly short of what it said it brings is the one
    // truncation that looks like success — no error, a whole-looking file.
    // The length the response declared is the only check a download has, and
    // a body no length was declared for (chunked) is not compared.
    final expected = response.contentLength;
    if (expected != null && received != expected) {
      throw HttpException(
          "$asset arrived at $received of $expected bytes");
    }
  }

  /// Per process, like [_stagingName]: two copies checking at once must not
  /// write, or arm, the same file.
  String _cacheStage(String asset) => p.join(cacheDir, "updates", "$pid-$asset");

  /// The name the staged file carries under this process, distinct from any
  /// other copy of the app running a check with its own — a file beside the
  /// AppImage on Linux, a directory beside the bundle on macOS.
  String get _stagingName => "${_stagingPrefix}update-$pid";

  /// Leftovers of a check that was killed: the staging names of this prefix,
  /// and the whole updates directory, where anything has sat more than a
  /// day. Age is the only guard a live staging needs — it is fresh.
  Future<void> _dropStale() async {
    final cutoff = DateTime.now().subtract(_stale);
    Future<void> sweep(String dir, bool Function(String name) stale) async {
      try {
        await for (final entry in Directory(dir).list()) {
          final name = p.basename(entry.path);
          if (!stale(name)) continue;
          if ((await entry.stat()).modified.isAfter(cutoff)) continue;
          if (entry is Directory) {
            await entry.delete(recursive: true);
          } else {
            await entry.delete();
          }
        }
      } catch (_) {
        // Housekeeping: whatever refused stays.
      }
    }

    switch (flavour) {
      case UpdateFlavour.linux:
        await sweep(p.dirname(appImage!), (name) => name.startsWith(_stagingPrefix));
      case UpdateFlavour.macos:
        // With the bundle missing, a swap's rollback failed and what is
        // beside it may be the only copy of the app left.
        if (bundle != null && await Directory(bundle!).exists()) {
          await sweep(p.dirname(bundle!), (name) => name.startsWith(_stagingPrefix));
        }
      case UpdateFlavour.windows:
        break;
    }
    await sweep(p.join(cacheDir, "updates"), (_) => true);
  }

  Future<void> _replaceAppImage(String staged) async {
    final image = appImage!;
    final mode = await Process.run("chmod", ["755", staged]);
    if (mode.exitCode != 0) {
      throw ProcessException(
          "chmod", ["755", staged], mode.stderr.toString(), mode.exitCode);
    }
    // POSIX: a name can be taken out from under a running binary. The inode
    // this process executes keeps it alive until it exits; the name is what
    // the next launch runs.
    await File(staged).rename(image);
  }

  Future<void> _swapBundle(String dmg) async {
    final running = bundle!;
    final parent = p.dirname(running);
    final name = p.basename(running);
    final mount = p.join(cacheDir, "updates", "mount-$pid");
    var attached = false;
    try {
      await Directory(mount).create(recursive: true);
      final attach = await Process.run("hdiutil", [
        "attach",
        "-nobrowse",
        "-readonly",
        "-noautoopen",
        "-mountpoint",
        mount,
        dmg,
      ]);
      if (attach.exitCode != 0) {
        throw ProcessException(
            "hdiutil", ["attach", dmg], attach.stderr.toString(),
            attach.exitCode);
      }
      attached = true;
      // One app in the image is what a release ships; anything else is not a
      // release this build was made from.
      final sources = [
        for (final entry in await Directory(mount).list().toList())
          if (entry is Directory && entry.path.endsWith(".app")) entry.path,
      ];
      if (sources.length != 1) {
        throw StateError("the release image holds ${sources.length} apps");
      }
      final staged = p.join(parent, _stagingName, name);
      final copy = await Process.run("ditto", [sources.single, staged]);
      if (copy.exitCode != 0) {
        throw ProcessException("ditto", [sources.single, staged],
            copy.stderr.toString(), copy.exitCode);
      }
      // The engine directory is the whole build in miniature: with nothing in
      // it the download is not an app, and swapping it in would take the
      // bundle the next start cannot run.
      final engine = Directory(p.join(staged, "Contents", "MacOS"));
      if (!await engine.exists() || await engine.list().isEmpty) {
        throw StateError("the downloaded bundle has no executable in it");
      }
      final aside = p.join(parent, "${_stagingPrefix}old-$pid", name);
      if (_renameSwap(staged, running)) {
        // The old bundle is now at the staged path; its directory becomes
        // the aside. Failing that, the sweep takes it under the staging name.
        try {
          await Directory(p.dirname(staged)).rename(p.dirname(aside));
        } catch (_) {}
      } else {
        await Directory(p.dirname(aside)).create(recursive: true);
        await Directory(running).rename(aside);
        try {
          await Directory(staged).rename(running);
        } catch (_) {
          // Between the two renames the location is empty. Fail there and
          // the old bundle goes back in, because an update that aborts must
          // never read as an uninstall.
          try {
            await Directory(aside).rename(running);
          } catch (error) {
            // Neither is in place: the discard and the sweep both leave the
            // two copies alone while the bundle path is missing.
            logFailure(_tag, "the old bundle could not be put back from "
                "$aside", error);
          }
          rethrow;
        }
      }
      // The old build is left for the sweep a day out rather than deleted
      // now. Nothing here reads it any more: what this process loads from
      // now on resolves by path, into the new bundle.
      try {
        await Directory(p.join(parent, _stagingName)).delete(recursive: true);
      } catch (_) {}
      // And the image with it, now that everything it held is elsewhere.
      try {
        await File(dmg).delete();
      } catch (_) {}
    } finally {
      if (attached) await _detach(mount);
      try {
        await Directory(mount).delete();
      } catch (_) {}
    }
  }

  /// hdiutil refuses a detach while anything still holds the volume —
  /// Spotlight, a ditto just finished — so it is retried, then forced, the
  /// way make-dmg.sh does.
  Future<void> _detach(String mount) async {
    Future<bool> detach(List<String> extra) async {
      try {
        final run = await Process.run(
            "hdiutil", ["detach", "-quiet", ...extra, mount]);
        if (run.exitCode == 0) return true;
        if (extra.isNotEmpty) {
          logFailure(_tag, "the update image would not detach", run.stderr);
        }
      } catch (error) {
        if (extra.isNotEmpty) {
          logFailure(_tag, "the update image would not detach", error);
        }
      }
      return false;
    }

    for (var attempt = 0; attempt < 3; attempt++) {
      if (await detach(const [])) return;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    await detach(const ["-force"]);
  }

  Future<void> _armInstaller(String msi) async {
    final script =
        windowsUpdateCommand(pid, msi, p.join(p.dirname(msi), "msi.log"));
    // A final public field does not promote, so the arm goes through a local.
    final arm = spawn;
    if (arm != null) {
      await arm(script);
      return;
    }
    await Process.start(
      "powershell.exe",
      ["-NoProfile", "-WindowStyle", "Hidden", "-Command", script],
      mode: ProcessStartMode.detached,
    );
  }

  /// Take back what a failed replace left behind. The download always goes —
  /// it is refetchable — and where the platform half staged more than the
  /// file, that goes too.
  Future<void> _discard(String staged) async {
    try {
      await File(staged).delete();
    } catch (_) {}
    final roots = <String>[
      // Not with the bundle missing: the staged copy may be the only app.
      if (flavour == UpdateFlavour.macos &&
          bundle != null &&
          await Directory(bundle!).exists())
        p.join(p.dirname(bundle!), _stagingName),
      if (await Directory(p.join(cacheDir, "updates", "mount-$pid")).exists())
        p.join(cacheDir, "updates", "mount-$pid"),
    ];
    for (final root in roots) {
      try {
        await Directory(root).delete(recursive: true);
      } catch (_) {}
    }
  }
}

/// What the exit-armed installer runs, one line: hold until the app is gone,
/// then install silently, under RunAs — the consent the user answers at
/// quit. RunAs is load-bearing, not decorative: silent mode suppresses the
/// elevation prompt itself, and a per-machine install that cannot ask fails
/// with "insufficient privileges" and nothing to show for it. Start-Process
/// joins -ArgumentList with bare spaces, so the paths carry their own double
/// quotes; the log at [logPath] is the only trace an install that failed
/// unattended leaves.
String windowsUpdateCommand(int pid, String msiPath, String logPath) {
  String quoted(String path) => "'\"${path.replaceAll("'", "''")}\"'";
  return "Wait-Process -Id $pid -ErrorAction SilentlyContinue; "
      "Start-Process msiexec.exe -Verb RunAs -ArgumentList '/i', "
      "${quoted(msiPath)}, '/qn', '/norestart', '/l*v', ${quoted(logPath)}";
}

/// [exe] where it is the MSI's install, under Program Files\Entoli (see
/// tool/windows/entoli.wxs), else null.
String? installedWindowsExe(String exe, Map<String, String> environment) {
  for (final root in [environment["ProgramW6432"], environment["ProgramFiles"]]) {
    if (root == null) continue;
    final folder = p.windows.join(root, "Entoli").toLowerCase();
    if (p.windows.isWithin(folder, exe.toLowerCase())) return exe;
  }
  return null;
}

typedef _RenamexNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Uint32);
typedef _Renamex = int Function(Pointer<Utf8>, Pointer<Utf8>, int);

/// Exchanges [a] and [b] in one step with macOS's renamex_np(RENAME_SWAP),
/// so no moment has neither in place. False where the call is not there or
/// refused, which the two-rename path answers.
bool _renameSwap(String a, String b) {
  const renameSwap = 0x00000002;
  try {
    final renamex = DynamicLibrary.process()
        .lookupFunction<_RenamexNative, _Renamex>("renamex_np");
    final from = a.toNativeUtf8();
    final to = b.toNativeUtf8();
    try {
      return renamex(from, to, renameSwap) == 0;
    } finally {
      malloc.free(from);
      malloc.free(to);
    }
  } catch (error) {
    logFailure(_tag, "renamex_np is not available", error);
    return false;
  }
}

/// The `.app` the running build executes from, or null where the executable
/// is not inside one. Three parents up from the engine, only the last of
/// which is allowed to be the answer.
String? _resolvedBundle() {
  final exe = Platform.resolvedExecutable;
  final bundle = p.dirname(p.dirname(p.dirname(exe)));
  return bundle.endsWith(".app") ? bundle : null;
}