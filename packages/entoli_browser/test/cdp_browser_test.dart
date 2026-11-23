import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;
import "package:entoli_browser/cdp_browser.dart"
    show CdpBrowser, looksLikeChallenge, pageAddress, reapLostBrowser;
import "package:entoli_browser/helium.dart";
import "package:entoli_core/model/agent_browser.dart";

void main() {
  test("a quit ends the hiding and any sign-in waiting on the user", () async {
    final dir = Directory.systemTemp.createTempSync("agent-browser-quit");
    addTearDown(() => dir.deleteSync(recursive: true));
    final browser = CdpBrowser(
      browserDir: dir.path,
      picked: () => null,
      embedded: HeliumDownload(dir.path),
      visible: () => false,
      environment: () => const {},
    );
    final tab = browser.tab("chat-1");
    tab.hide(const BrowserHold(reason: "Sign in to Google"));
    final waiting = tab.requestCredentials(
      const CredentialRequest(
        reason: "Sign in",
        fields: [CredentialField(ref: 1, label: "Email")],
      ),
    );
    // Listened to before the quit fails it, as the waiting agent is.
    final declined = expectLater(waiting, throwsA(isA<CredentialsDeclined>()));
    await browser.close();
    expect(tab.hold.value, isNull);
    expect(tab.credentialRequest.value, isNull);
    await declined;
  });

  test(
    "a browser left running on the profile is quit before a launch",
    () async {
      final dir = Directory.systemTemp.createTempSync("agent-browser-lost");
      addTearDown(() => dir.deleteSync(recursive: true));
      final profile = p.join(dir.path, "profile");
      // `; :` keeps the shell from exec'ing sleep, which would drop the flag.
      Future<Process> holder(String flag) =>
          Process.start("sh", ["-c", "sleep 30; :", "sh", flag]);
      final lost = await holder("--user-data-dir=$profile");
      final other = await holder("--user-data-dir=${dir.path}/elsewhere");
      addTearDown(other.kill);
      final lock = Link(p.join(profile, "SingletonLock"))
        ..createSync("${Platform.localHostname}-${lost.pid}", recursive: true);

      await reapLostBrowser(profile);
      expect(await lost.exitCode.timeout(const Duration(seconds: 5)), isNot(0));

      lock
        ..deleteSync()
        ..createSync("${Platform.localHostname}-${other.pid}");
      await reapLostBrowser(profile);
      expect(
        await other.exitCode
            .then<int?>((code) => code)
            .timeout(const Duration(milliseconds: 300), onTimeout: () => null),
        isNull,
      );
    },
    skip: Platform.isWindows,
  );

  test(
    "deleting the browser's data takes the profile, not the download",
    () async {
      final dir = Directory.systemTemp.createTempSync("agent-browser-clear");
      addTearDown(() => dir.deleteSync(recursive: true));
      File("${dir.path}/profile/Default/Cookies").createSync(recursive: true);
      File("${dir.path}/download/kept").createSync(recursive: true);
      final browser = CdpBrowser(
        browserDir: dir.path,
        picked: () => null,
        embedded: HeliumDownload(dir.path),
        visible: () => false,
        environment: () => const {},
      );
      final tab = browser.tab("chat-1");
      tab.hide(const BrowserHold(reason: "Sign in to Google"));
      await browser.clearData();
      expect(Directory("${dir.path}/profile").existsSync(), isFalse);
      expect(File("${dir.path}/download/kept").existsSync(), isTrue);
      expect(tab.hold.value, isNull);
    },
  );

  test("Helium's assets are named as its releases name them", () {
    expect(
      heliumAsset(HeliumOs.linux, "0.20.1.1", arm: false),
      "helium-0.20.1.1-x86_64.AppImage",
    );
    expect(
      heliumAsset(HeliumOs.macos, "0.20.1.1", arm: true),
      "helium_0.20.1.1_arm64-macos.dmg",
    );
    expect(
      heliumAsset(HeliumOs.windows, "0.20.1.1", arm: false),
      "helium_0.20.1.1_x64-windows.zip",
    );
  });

  test("an address with no scheme is https, or http on this machine", () {
    expect(pageAddress("example.com/a"), "https://example.com/a");
    expect(pageAddress("localhost:8080"), "http://localhost:8080");
    expect(pageAddress("127.0.0.1:3000/x"), "http://127.0.0.1:3000/x");
    expect(
      pageAddress("localhost.example.com"),
      "https://localhost.example.com",
    );
    expect(pageAddress("http://localhost:8080"), "http://localhost:8080");
    expect(pageAddress("about:blank"), "about:blank");
  });

  group("a challenge", () {
    test("is a challenge frame, or a page saying it is one", () {
      expect(
        looksLikeChallenge("Shop", "", [
          "https://challenges.cloudflare.com/cdn-cgi/challenge-platform/x",
        ]),
        isTrue,
      );
      expect(looksLikeChallenge("Just a moment...", "", const []), isTrue);
      expect(
        looksLikeChallenge("News", "Today's headlines", const []),
        isFalse,
      );
    });
  });
}
