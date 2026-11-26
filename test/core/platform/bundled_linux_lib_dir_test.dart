import "package:flutter_test/flutter_test.dart";
import "package:agent_chat/core/platform/host.dart";

/// The path the Linux build looks for its model server at is the whole of
/// what turns a staged binary into a working feature, and it is pure over the
/// executable's path — so it can be pinned on any machine, the bargain
/// `proot_test.dart` makes for the guest driver. Two branches, one per shape
/// of directory the executable is found in.
void main() {
  const gb = 1024 * 1024 * 1024;

  test("a phone's models get seven tenths of the smaller reading, the "
      "iPhone 18 Pro's fitting the 4B", () {
    final memory = appleMemoryOf({
      "workingSet": 8 * gb,
      "available": 6 * gb,
    }, mac: false)!;
    expect(memory.total, 6 * gb);
    expect(memory.budget.bytes, 6 * gb * 7 ~/ 10);
    expect(memory.readings.map((r) => r.label), [
      "Graphics memory",
      "App headroom",
    ]);
    // Without its binding limit a phone's budget is not measured, though the
    // reading it did give is still shown.
    final partial = appleMemoryOf({"workingSet": 8 * gb}, mac: false)!;
    expect(partial.budget.bytes, isNull);
    expect(partial.readings.single.label, "Graphics memory");
    expect(appleMemoryOf({"workingSet": 8 * gb}, mac: true)!.total, 8 * gb);
  });

  test("Linux's RAM, with what is free beside it", () {
    final memory = linuxMemoryOf(
      "MemTotal:       16777216 kB\nMemAvailable:    8388608 kB\n",
    )!;
    expect(memory.total, 16 * gb);
    expect(memory.budget.bytes, 16 * gb * 3 ~/ 5);
    expect(memory.readings.map((r) => r.bytes), [16 * gb, 8 * gb]);
    expect(linuxMemoryOf(null), isNull);
  });

  test("the lib/ beside the executable, never a lib/ inside it", () {
    // What `flutter build linux` produces, and what the AppImage carries —
    // the AppDir's usr/bin is the same shape.
    expect(
      bundledLinuxLibDir(
        executablePath: "/repo/build/linux/x64/release/bundle/agent_chat",
      ),
      "/repo/build/linux/x64/release/bundle/lib",
    );
    // An executable already in lib/ does not grow a second lib.
    expect(
      bundledLinuxLibDir(
        executablePath: "/repo/build/linux/x64/release/bundle/lib/agent_chat",
      ),
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

  test("the RAM is read off MemTotal, in bytes", () {
    expect(
      linuxTotalMemory("MemTotal:       16314552 kB\nMemFree: 1 kB\n"),
      16314552 * 1024,
    );
    expect(linuxTotalMemory("MemFree: 1 kB\n"), isNull);
    expect(linuxTotalMemory(null), isNull);
  });
}
