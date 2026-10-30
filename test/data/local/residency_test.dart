import "package:agent_chat/data/local/residency.dart";
import "package:agent_chat/domain/local_llm.dart";
import "package:flutter_test/flutter_test.dart";

import "../../fakes.dart";

// The one rule every runtime gets for loading a model, over a runtime that
// only records what it was asked to do.
void main() {
  late FakeLocalRuntime runtime;
  late Residency residency;

  setUp(() {
    runtime = FakeLocalRuntime();
    residency = Residency(
      runtime,
      FakeLocalModelStore(installed: {"a", "b", "c"}),
    );
  });

  List<String> loaded() => [for (final s in residency.running.value) s.modelId];

  test("a displaced model is stopped before the next one loads", () async {
    await residency.serve("a", testLocalOptions());
    await residency.serve("b", testLocalOptions());

    // Overlapping them would put two sets of weights in memory at once,
    // which is the thing the cap exists to prevent.
    expect(runtime.events, ["load a", "stop a", "load b"]);
    expect(loaded(), ["b"]);
  });

  test("a model loaded under the same settings is not loaded again", () async {
    final first = await residency.serve("a", testLocalOptions());
    final second = await residency.serve("a", testLocalOptions());

    expect(identical(first, second), isTrue);
    expect(runtime.events, ["load a"]);
  });

  test("different settings reload it, the old one stopped first", () async {
    await residency.serve("a", testLocalOptions());
    await residency.serve("a", testLocalOptions(device: "Vulkan0"));

    expect(runtime.events, ["load a", "stop a", "load a"]);
    expect(residency.running.value.single.device, "Vulkan0");
  });

  test("the least recently served is the one displaced", () async {
    final two = testLocalOptions(maxRunning: 2);
    await residency.serve("a", two);
    await residency.serve("b", two);
    await residency.serve("a", two);
    await residency.serve("c", two);

    expect(loaded(), ["a", "c"]);
    expect(runtime.events.where((e) => e.startsWith("stop")), ["stop b"]);
  });

  test("a failed load is tried again when it is asked for again", () async {
    runtime = FakeLocalRuntime(ready: false);
    residency = Residency(runtime, FakeLocalModelStore(installed: {"a"}));

    for (var i = 0; i < 2; i++) {
      await expectLater(
        residency.serve("a", testLocalOptions()),
        throwsA(isA<LocalLlmFailure>()),
      );
    }

    expect(runtime.events, ["load a", "stop a", "load a"]);
    expect(residency.running.value.single.phase, LocalLlmPhase.failed);
  });

  test("one model can be stopped and the rest left loaded", () async {
    final two = testLocalOptions(maxRunning: 2);
    await residency.serve("a", two);
    await residency.serve("b", two);

    await residency.stop("a");

    expect(loaded(), ["b"]);
    expect(runtime.events.last, "stop a");
  });

  test("a lost process forgets its models without stopping them", () async {
    await residency.serve("a", testLocalOptions());

    residency.lost();

    expect(loaded(), isEmpty);
    expect(runtime.stops, 0);
  });
}
