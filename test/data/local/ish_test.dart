import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/rootfs.dart";
import "package:agent_chat/domain/shell.dart";
import "package:agent_chat/data/local/ish_ffi.dart";

/// What can be pinned on a machine with no iOS on it: the shared dispatcher
/// script (the wire protocol both LocalShell and IshShell run), the i386
/// rootfs catalog entry, and that the FFI bridge is not linked off iOS.
void main() {
  group("the dispatcher script", () {
    test("carries the token so a command's output cannot forge the end of a run",
        () {
      final script = dispatcherScript("abc123");
      expect(script, contains("@@Eabc123"));
    });

    test("traps INT so the shell survives a Ctrl-C the way LocalShell's does",
        () {
      final script = dispatcherScript("t");
      expect(script, contains("trap 'true' INT"));
    });

    test("traps EXIT so a shell that dies still reports where it stood", () {
      final script = dispatcherScript("t");
      expect(script, contains("trap '"));
      expect(script, contains("EXIT"));
    });

    test("evaluates base64 lines, not raw stdin, so a quote cannot steal a line",
        () {
      final script = dispatcherScript("t");
      expect(script, contains("base64 -d"));
      expect(script, contains("IFS= read -r line"));
    });

    test("the marker is the dispatcher's, so what scans is what wrote", () {
      expect(dispatcherMarker("xyz"), "@@Exyz rc=");
    });
  });

  group("the i386 rootfs for iOS", () {
    final image = alpine.imageFor("ios");

    test("exists, since iSH emulates x86 and not the device's arm64", () {
      expect(image, isNotNull);
    });

    test("is the i386 Alpine minirootfs, not the arm64 one Android fetches", () {
      expect(image!.arch, "i386");
      expect(image.url, contains("/x86/"));
      expect(image.url, contains("alpine-minirootfs-3.24.1-x86.tar.gz"));
    });

    test("is checked before anything is unpacked, since it is a Linux that runs",
        () {
      expect(image!.sha256,
          "634355e2245c9d56186d1b86fb6e034453eb303aea15b573ca250b343376fffd");
    });

    test("the size is exact, so the bar reads before the first byte arrives", () {
      expect(image!.bytes, 3538048);
    });

    test("the ios key is the only non-Android one the catalog carries", () {
      final keys = alpine.images.keys.toSet();
      expect(keys, containsAll(["arm64-v8a", "armeabi-v7a", "x86_64", "ios"]));
      expect(keys.length, 4);
    });

    test("describe names the i386 arch, since that is what uname -m says inside",
        () {
      expect(alpine.describe("ios"), contains("i386"));
    });
  });

  group("the FFI bridge", () {
    test("is not linked off iOS, so the symbols are never looked up", () {
      expect(ishLinked, isFalse,
          reason: "iSH is only linked on iOS; on every other platform the "
              "FFI lookups are never made and the build carries no iSH.");
    });
  });
}
