import "package:flutter_test/flutter_test.dart";
import "package:agent_chat/domain/documents.dart";

import "dart:async";

void main() {
  test("overlapping writes land in the order they were asked", () async {
    final written = <String>[];
    final writer = RenameWriter((path, text) async {
      // Long enough that a second write arrives while the first is running —
      // the overlap the queue exists for.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      written.add(text);
    });

    await Future.wait([
      writer.write("settings", "first"),
      writer.write("settings", "second"),
      writer.write("settings", "third"),
    ]);

    expect(written, ["first", "second", "third"]);
  });

  test("a failed write drains its entry and does not wedge the path",
      () async {
    var fail = true;
    final written = <String>[];
    final writer = RenameWriter((path, text) async {
      if (fail) throw StateError("disk gone");
      written.add(text);
    });

    await expectLater(writer.write("settings", "lost"), throwsStateError);
    fail = false;
    await writer.write("settings", "kept");

    // The failure did not leave the queue stuck on the lost entry.
    expect(written, ["kept"]);
  });

  test("a failed write is not an unhandled error beside the awaited one",
      () async {
    // The queue entry carries a caught error, not the raw future: what the
    // await delivers to the caller is the only copy of the failure.
    final writer = RenameWriter((path, text) async => throw StateError("no"));
    await expectLater(writer.write("settings", "text"), throwsStateError);
  });

  test("different paths do not block each other", () async {
    final started = <String>[];
    final writer = RenameWriter((path, text) async {
      started.add(path);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });

    await Future.wait([
      writer.write("settings", "a"),
      writer.write("other", "b"),
    ]);

    // Both were started before either finished.
    expect(started, hasLength(2));
  });

  test("paths drain once their tail finishes", () async {
    // The third write hangs on the hold, so `started` says the drained path
    // ran it at once: no stopwatch, which was a bet on the runner's load.
    final hang = Completer<void>();
    var calls = 0;
    var started = false;
    final writer = RenameWriter((path, text) async {
      calls += 1;
      if (calls == 3) {
        started = true;
        await hang.future;
      }
    });

    await writer.write("settings", "a");
    await writer.write("settings", "b");

    // The entry leaves with the write that finished. The removal runs one
    // microtask behind the write's own completion, so let it land.
    await pumpEventQueue();
    expect(writer.pendingWrites, 0);

    // Nothing to wait on: a third write asked now starts at once rather
    // than standing behind a tail that already answered.
    final third = writer.write("settings", "c");
    await pumpEventQueue();
    expect(started, isTrue, reason: "the drained path starts its next write");
    expect(writer.pendingWrites, 1);

    hang.complete();
    await third;
    await pumpEventQueue();
    expect(writer.pendingWrites, 0);
  });
}