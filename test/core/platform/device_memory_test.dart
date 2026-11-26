import "package:flutter_test/flutter_test.dart";
import "package:agent_chat/core/platform/host.dart";

/// What each platform's readings make of a device's memory: the whole, the
/// models' share of it, and the readings shown under the bar.
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
}
