import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/platform/host.dart";

/// The path the Linux build looks for its model server at is the whole of
/// what turns a staged binary into a working feature, and it is pure over the
/// executable's path — so it can be pinned on any machine, the bargain
/// `proot_test.dart` makes for the guest driver. Two branches, one per shape
/// of directory the executable is found in.
void main() {
  test("the lib/ beside the executable, never a lib/ inside it", () {
    // What `flutter build linux` produces, and what the AppImage carries —
    // the AppDir's usr/bin is the same shape.
    expect(
      bundledLinuxLibDir(
          executablePath: "/repo/build/linux/x64/release/bundle/agent_chat"),
      "/repo/build/linux/x64/release/bundle/lib",
    );
    // An executable already in lib/ does not grow a second lib.
    expect(
      bundledLinuxLibDir(
          executablePath: "/repo/build/linux/x64/release/bundle/lib/agent_chat"),
      "/repo/build/linux/x64/release/bundle/lib",
    );
    // A bare install has no lib/ beside it, so the answer names one that does
    // not exist — and the exists() check the caller makes of it is the honest
    // "no server" rather than a null here.
    expect(
      bundledLinuxLibDir(executablePath: "/usr/bin/entoli"),
      "/usr/bin/lib",
    );
  });
}