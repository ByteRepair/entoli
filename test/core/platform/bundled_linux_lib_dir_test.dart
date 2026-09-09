import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/platform/io/platform.dart";

/// The path the Linux build looks for its model server at is the whole of
/// what turns a staged binary into a working feature, and it is pure over the
/// executable's path — so it can be pinned on any machine, the bargain
/// `proot_test.dart` makes for the guest driver.
void main() {
  test("a bundle's own layout is the lib/ beside the executable", () {
    // What `flutter build linux` produces, and what the AppImage carries —
    // the AppDir's usr/bin is the same shape.
    expect(
      bundledLinuxLibDir(
          executablePath: "/repo/build/linux/x64/release/bundle/agent_chat"),
      "/repo/build/linux/x64/release/bundle/lib",
    );
  });

  test("an executable already in lib/ does not grow a second lib", () {
    expect(
      bundledLinuxLibDir(
          executablePath: "/repo/build/linux/x64/release/bundle/lib/agent_chat"),
      "/repo/build/linux/x64/release/bundle/lib",
    );
  });

  test("the name of the executable is nobody's business but the directory's",
      () {
    // Renamed binaries are how AppImages and desktop entries get tried out;
    // the answer follows the directory, not the name.
    expect(
      bundledLinuxLibDir(executablePath: "/opt/entoli/AppRun"),
      "/opt/entoli/lib",
    );
    // A bare install has no lib/ beside it, so the answer names one that does
    // not exist — and the exists() check upstream answers that, which is the
    // honest "no server" rather than a wrong path.
    expect(
      bundledLinuxLibDir(executablePath: "/usr/bin/entoli"),
      "/usr/bin/lib",
    );
  });
}