import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/turn_keep_alive.dart";

import "../fakes.dart";

void main() {
  late FakeBackend backend;
  late FakeBackgroundWork work;
  late TurnKeepAlive keepAlive;

  setUp(() {
    backend = FakeBackend();
    work = FakeBackgroundWork();
    keepAlive = TurnKeepAlive(backend, work);
  });

  tearDown(() => keepAlive.dispose());

  test("the platform is told how many turns are running", () {
    backend.runningTurns.value = {"a"};
    backend.runningTurns.value = {"a", "b"};
    backend.runningTurns.value = {"b"};
    backend.runningTurns.value = {};

    expect(work.told, [1, 2, 1, 0]);
  });

  test("stop aborts every running turn", () async {
    backend.runningTurns.value = {"a", "b"};

    work.stop();
    await pumpEventQueue();

    expect(backend.aborted, unorderedEquals(["a", "b"]));
    // Aborting is what empties the backend, which is what releases the hold —
    // the notification goes when the work does, not when the button is pressed.
    expect(work.told.last, 0);
  });

  test("nothing is told after dispose", () {
    keepAlive.dispose();

    backend.runningTurns.value = {"a"};

    expect(work.told, isEmpty);
  });
}
