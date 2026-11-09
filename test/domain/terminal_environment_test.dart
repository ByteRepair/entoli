import "package:agent_chat/domain/rootfs.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  group("terminalEnvironment", () {
    test("a guest reports its own arch and that it can install", () {
      final env = terminalEnvironment(rootfsId: alpine64.id, deviceAbi: "ios");
      expect(env.arch, "x86_64");
      expect(env.supportsInstalls, isTrue);

      final i386 = terminalEnvironment(rootfsId: alpine.id, deviceAbi: "ios");
      expect(i386.arch, "i386");
      expect(i386.supportsInstalls, isTrue);
    });

    test("the host reports the device's ABI and cannot install", () {
      final android = terminalEnvironment(
        rootfsId: null,
        deviceAbi: "arm64-v8a",
      );
      expect(android.arch, "arm64-v8a");
      expect(android.supportsInstalls, isFalse);

      // iOS's host has no architecture at all: nothing runs on it.
      final ios = terminalEnvironment(rootfsId: null, deviceAbi: "ios");
      expect(ios.arch, isNull);
      expect(ios.supportsInstalls, isFalse);
    });

    test("is64BitArch names the arches a CLI binary ships for", () {
      expect(is64BitArch("x86_64"), isTrue);
      expect(is64BitArch("aarch64"), isTrue);
      expect(is64BitArch("arm64-v8a"), isTrue);
      expect(is64BitArch("i386"), isFalse);
      expect(is64BitArch("armv7"), isFalse);
      expect(is64BitArch(null), isFalse);
    });
  });
}
