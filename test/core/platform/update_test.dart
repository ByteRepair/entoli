import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;

import "package:agent_chat/core/platform/io/update.dart";
import "package:agent_chat/domain/app_update.dart";

import "../../data/fake_network.dart";

/// The release check over a network with no socket under it, and the
/// replaces-itself halves that are this repo's own contract: the AppImage
/// renamed over the file a build runs from, and the bundle swap mounted for
/// real. The macOS halves want hdiutil and ditto, so they run where those do;
/// everything else runs wherever dart:io does.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync("entoli-update"));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// The release the page answers with: the redirect's tag, and past it the
  /// asset under that tag. [body] arrives as one piece — the check never
  /// stops halfway, so halves would prove only that they arrive.
  FakeNetwork release(String tag, String asset, List<int> body) => FakeNetwork(
        {
          "/$updateRepo/releases/latest": const [
            <int>[],
          ],
          "/$updateRepo/releases/download/$tag/$asset": [body],
        },
        headers: {
          "location": "https://github.com/$updateRepo/releases/tag/$tag",
        },
      );

  /// The Linux updater a check test uses, over [image] as the AppImage this
  /// build is said to run from and [network] as the release page.
  DesktopUpdater linuxUpdater(String image, FakeNetwork network) =>
      DesktopUpdater(
        flavour: UpdateFlavour.linux,
        cacheDir: tmp.path,
        appImage: image,
        // A test run is a debug build to kDebugMode; the check is what is
        // under test.
        debug: false,
        httpClient: network,
      );

  group("the check", () {
    test("puts a newer, executable AppImage over the file the build runs from",
        () async {
      final image = File("${tmp.path}/entoli-x86_64.AppImage")
        ..writeAsStringSync("old");
      final network = release("v1.3.0", appImageAsset, "new".codeUnits);

      await linuxUpdater(image.path, network).check(
          version: "1.2.3", enabled: true);

      expect(image.readAsStringSync(), "new");
      expect(network.asked, 2, reason: "the redirect and the download");
      expect(image.statSync().mode & 0x40 != 0, isTrue,
          reason: "chmod ran before the rename");
      expect(tmp.listSync().where((e) => e.path.contains(".entoli-")),
          isEmpty, reason: "the staged file was renamed in, not copied");
    }, skip: Platform.isWindows ? "POSIX only" : null);

    test("stops at the redirect when the tag is not newer", () async {
      final image = File("${tmp.path}/entoli-x86_64.AppImage")
        ..writeAsStringSync("old");
      for (final running in ["2.0.0", "1.3.0"]) {
        final network = release("v1.3.0", appImageAsset, "new".codeUnits);

        await linuxUpdater(image.path, network)
            .check(version: running, enabled: true);

        expect(network.asked, 1, reason: "the redirect, and not the asset");
      }
      expect(image.readAsStringSync(), "old");
    });

    test("off, an unknown version, or a debug run asks nothing at all",
        () async {
      final network = release("v1.3.0", appImageAsset, "new".codeUnits);
      final image = "${tmp.path}/entoli-x86_64.AppImage";

      await linuxUpdater(image, network).check(version: "1.2.3", enabled: false);
      await linuxUpdater(image, network).check(version: null, enabled: true);
      await DesktopUpdater(
        flavour: UpdateFlavour.linux,
        cacheDir: tmp.path,
        appImage: image,
        debug: true,
        httpClient: network,
      ).check(version: "1.2.3", enabled: true);

      expect(network.asked, 0);
    });

    test("a missing asset is a change of nothing", () async {
      final image = File("${tmp.path}/entoli-x86_64.AppImage")
        ..writeAsStringSync("old");
      // The redirect stands and nothing is at the download path — the way a
      // release that carries one asset fewer answers.
      final network = FakeNetwork({}, missingAs404: true, headers: {
        "location": "https://github.com/$updateRepo/releases/tag/v1.3.0",
      });

      await linuxUpdater(image.path, network)
          .check(version: "1.2.3", enabled: true);

      expect(image.readAsStringSync(), "old");
    });

    test("a network that is not there takes nothing down", () async {
      final image = File("${tmp.path}/entoli-x86_64.AppImage")
        ..writeAsStringSync("old");
      // One body anywhere would pass the newest-version check. With none, the
      // release page itself refuses, which is what a dead dial fails at.
      final network = FakeNetwork({});

      await linuxUpdater(image.path, network)
          .check(version: "1.2.3", enabled: true);

      expect(image.readAsStringSync(), "old");
    });

    test("a body that arrives short of its declared length is refused",
        () async {
      final image = File("${tmp.path}/entoli-x86_64.AppImage")
        ..writeAsStringSync("old");
      // Three of the four bytes the response declares, and no error — the
      // eof a broken CDN hands over, which reads as a whole file.
      await DesktopUpdater(
        flavour: UpdateFlavour.linux,
        cacheDir: tmp.path,
        appImage: image.path,
        debug: false,
        httpClient: _ShortBody("fresh".codeUnits.sublist(0, 3), 4),
      ).check(version: "1.2.3", enabled: true);

      expect(image.readAsStringSync(), "old",
          reason: "a partial build is never put in place");
      expect(tmp.listSync().where((e) => e.path.contains(".entoli-")),
          isEmpty, reason: "the partial download goes with the refusal");
    });
  });

  group("Windows", () {
    test("arms the exit-armed installer and keeps the download", () async {
      final network = release("v1.3.0", msiAsset, "installer".codeUnits);
      final scripts = <String>[];
      final updater = DesktopUpdater(
        flavour: UpdateFlavour.windows,
        cacheDir: tmp.path,
        httpClient: network,
        spawn: (script) async => scripts.add(script),
        debug: false,
      );

      await updater.check(version: "1.2.3", enabled: true);

      final msi = File("${tmp.path}/updates/$msiAsset");
      expect(msi.readAsBytesSync(), "installer".codeUnits,
          reason: "the waiter installs this once the process is gone");
      expect(scripts, hasLength(1));
      expect(scripts.single, contains("Wait-Process -Id"));
      expect(scripts.single, contains("-Verb RunAs"),
          reason: "silent mode suppresses the elevation prompt; RunAs asks");
      expect(scripts.single, contains("'/qn'"));
      expect(scripts.single, contains("'${msi.path}'"));
    });

    test("the waiter waits for the app and installs the quoted path silently",
        () {
      final script = windowsUpdateCommand(4242, r"C:\Users\a b\entoli.msi");
      expect(script, startsWith("Wait-Process -Id 4242 "));
      expect(script, contains("-Verb RunAs"),
          reason: "the per-machine install cannot elevate itself; RunAs "
              "is the prompt the user answers at quit");
      expect(script, contains("'/i'"));
      expect(script, contains("'/qn'"));
      expect(script, contains("'/norestart'"));
      expect(script, contains(r"'C:\Users\a b\entoli.msi'"),
          reason: "an unquoted path with a space is two arguments");
      expect(windowsUpdateCommand(1, r"C:\Users\a'b\entoli.msi"),
          contains(r"'C:\Users\a''b\entoli.msi'"));
    });
  });

  group("macOS", () {
    /// A bundle at [name] with the engine whose contents tell old from new —
    /// the two files the swap's own check looks at. [at] is a directory the
    /// bundle is written into whole: the Applications directory for the one
    /// running, the volume tree for one staged into the release.
    void bundle(String at, String name, String engine) {
      final macos = Directory("$at/$name/Contents/MacOS")
        ..createSync(recursive: true);
      File("${macos.path}/entoli").writeAsStringSync(engine);
      File("${macos.parent.path}/Info.plist").writeAsStringSync("<plist/>");
    }

    /// The volume the release ships: the staged tree, and the image made of
    /// it the way `make-dmg.sh` makes the release's.
    File package(String tree) {
      final dmg = File("${tmp.path}/release.dmg");
      final run = Process.runSync("hdiutil", [
        "create",
        "-ov",
        "-volname",
        "Entoli",
        "-srcfolder",
        tree,
        "-format",
        "UDZO",
        dmg.path,
      ]);
      expect(run.exitCode, 0, reason: run.stderr.toString());
      return dmg;
    }

    DesktopUpdater appUpdater(FakeNetwork network) => DesktopUpdater(
          flavour: UpdateFlavour.macos,
          cacheDir: "${tmp.path}/cache",
          bundle: "${tmp.path}/Applications/Entoli.app",
          httpClient: network,
          debug: false,
        );

    test("a newer release swaps the bundle under the running one", () async {
      // The staged tree is the volume's root: what the image mounts as.
      final tree = Directory("${tmp.path}/volume/")..createSync();
      bundle(tree.path, "Entoli.app", "new-engine");
      final dmg = package(tree.path);
      bundle("${tmp.path}/Applications", "Entoli.app", "old-engine");
      final applications = Directory("${tmp.path}/Applications");

      await appUpdater(release("v1.3.0", dmgAsset, dmg.readAsBytesSync()))
          .check(version: "1.2.3", enabled: true);

      expect(
          File("${applications.path}/Entoli.app/Contents/MacOS/entoli")
              .readAsStringSync(),
          "new-engine");
      // The image is gone once the swap landed, and with it anything staged
      // beside the bundle or mounted for the copy.
      expect(File("${tmp.path}/cache/updates/$dmgAsset").existsSync(),
          isFalse, reason: "put in place is not keep a copy");
      expect(Directory("${tmp.path}/cache/updates/mount-$pid").existsSync(),
          isFalse);
      expect(
          applications
              .listSync()
              .where((e) => e.path.contains(".entoli-update")),
          isEmpty);
      // The old build waits under `.entoli-old-` for the sweep a day out:
      // this process may still read from the bundle it just left.
      expect(
          File("${applications.path}/.entoli-old-$pid/"
                  "Entoli.app/Contents/MacOS/entoli")
              .readAsStringSync(),
          "old-engine");
    });

    test("refuses a download that is not an app, and keeps the old one",
        () async {
      // The staged tree has the bundle's shape and nothing in the engine
      // directory, which is the whole of what "the app came over whole"
      // means to a check.
      final tree = Directory("${tmp.path}/volume/")..createSync();
      final noEngine = Directory("${tree.path}/Entoli.app/Contents")
        ..createSync(recursive: true);
      File("${noEngine.path}/Info.plist").writeAsStringSync("<plist/>");
      final dmg = package(tree.path);
      bundle("${tmp.path}/Applications", "Entoli.app", "old-engine");
      final applications = Directory("${tmp.path}/Applications");

      await appUpdater(release("v1.3.0", dmgAsset, dmg.readAsBytesSync()))
          .check(version: "1.2.3", enabled: true);

      expect(
          File("${applications.path}/Entoli.app/Contents/MacOS/entoli")
              .readAsStringSync(),
          "old-engine");
      expect(
          applications
              .listSync()
              .where((e) => e.path.contains(".entoli-")),
          isEmpty,
          reason: "the check takes its staging back");
      expect(File("${tmp.path}/cache/updates/$dmgAsset").existsSync(),
          isFalse, reason: "the refused download goes with the refusal");
    });

    test("refuses a release image that holds two apps", () async {
      final tree = Directory("${tmp.path}/volume/")..createSync();
      bundle(tree.path, "Entoli.app", "new-engine");
      bundle(tree.path, "Second.app", "other-engine");
      final dmg = package(tree.path);
      bundle("${tmp.path}/Applications", "Entoli.app", "old-engine");
      final applications = Directory("${tmp.path}/Applications");

      await appUpdater(release("v1.3.0", dmgAsset, dmg.readAsBytesSync()))
          .check(version: "1.2.3", enabled: true);

      expect(
          File("${applications.path}/Entoli.app/Contents/MacOS/entoli")
              .readAsStringSync(),
          "old-engine");
      expect(File("${tmp.path}/cache/updates/$dmgAsset").existsSync(),
          isFalse, reason: "the refused download goes with the refusal");
    });
  }, skip: !Platform.isMacOS ? "hdiutil and ditto" : null);
}

/// The release page for the one case FakeNetwork cannot play: a body that
/// ends cleanly short of the length its response declared, which is what a
/// broken CDN hands a download that "succeeds".
class _ShortBody extends http.BaseClient {
  _ShortBody(this.body, this.declared);

  final List<int> body;
  final int? declared;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith("releases/latest")) {
      return http.StreamedResponse(
        Stream.empty(),
        302,
        headers: {
          "location": "https://github.com/$updateRepo/releases/tag/v1.3.0",
        },
        request: request,
      );
    }
    return http.StreamedResponse(
      Stream.value(body),
      200,
      contentLength: declared,
      request: request,
    );
  }
}