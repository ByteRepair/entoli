import "dart:async";

import "package:clock/clock.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/file_watches.dart";
import "package:agent_chat/domain/trigger.dart";
import "package:agent_chat/domain/trigger_kinds.dart";

/// The watcher a test drives: events it [push]es, against a root it
/// remembers being asked for.
class FakeFileWatches implements FileWatches {
  final roots = <String>[];

  final _events = StreamController<FileWatchEvent>.broadcast();

  void push(FileWatchEvent event) => _events.add(event);

  @override
  bool get available => true;

  @override
  Stream<FileWatchEvent> watch(String root) {
    roots.add(root);
    return _events.stream;
  }
}

final _now = Clock.fixed(DateTime(2026, 8, 23, 9));

Trigger fileTrigger({
  String id = "f1",
  List<String> paths = const ["notes/"],
  Set<FileEvent> events = const {
    FileEvent.create,
    FileEvent.change,
    FileEvent.delete,
    FileEvent.move,
  },
  Duration cooldown = const Duration(seconds: 5),
  bool enabled = true,
}) =>
    Trigger(
      id: id,
      name: id,
      prompt: "p",
      source: FileSource(paths: paths, events: events, cooldown: cooldown),
      enabled: enabled,
    );

void main() {
  late FakeFileWatches watches;

  setUp(() {
    watches = FakeFileWatches();
  });

  FileKind kind({Future<String> Function(Trigger, String)? resolve}) => FileKind(
        fileWatches: watches,
        resolve: resolve ?? (trigger, path) async => "/ws/$path",
      );

  test("arms only where there are paths and a resolver", () {
    expect(kind().armed(fileTrigger()), isTrue);
    expect(kind().armed(fileTrigger(paths: [])), isFalse);
    expect(
        FileKind(fileWatches: watches).armed(fileTrigger()), isFalse);
    expect(kind().armed(fileTrigger(enabled: false)), isFalse);
    // Never matches another kind's source.
    expect(
        kind().armed(Trigger(
            id: "s", name: "", prompt: "", source: ScheduleSource(at: DateTime(2026)))),
        isFalse);
  });

  test("one root is one watcher over many triggers naming the same one",
      () async {
    final fires = kind().watch(
        [fileTrigger(id: "a"), fileTrigger(id: "b", paths: ["notes/"])], _now);
    // The stream subscribes lazily on await; poke it with a first-listen.
    final sub = fires.listen((_) {});
    await pumpEventQueue();
    expect(watches.roots.where((r) => r == "/ws/notes/"), hasLength(1));

    await sub.cancel();
  });

  test("an event under a watched root fires each trigger that named it",
      () async {
    final collected = <TriggerFire>[];
    final fires = kind().watch(
        [fileTrigger(id: "a"), fileTrigger(id: "b", paths: ["notes/todo.md"])],
        _now);
    final sub = fires.listen(collected.add);
    await pumpEventQueue();

    watches.push(const FileWatchEvent(
        path: "/ws/notes/todo.md", kind: FileEventKind.modify));
    await pumpEventQueue();

    expect(collected.map((f) => f.triggerId), containsAll(["a", "b"]));
    expect(collected.first.reason, contains("todo.md"));
    await sub.cancel();
  });

  test("an event of a kind the trigger did not name does not fire", () async {
    final collected = <TriggerFire>[];
    final fires = kind()
        .watch([fileTrigger(id: "a", events: {FileEvent.change})], _now);
    final sub = fires.listen(collected.add);
    await pumpEventQueue();

    watches.push(const FileWatchEvent(
        path: "/ws/notes/a.md", kind: FileEventKind.delete));
    await pumpEventQueue();
    expect(collected, isEmpty);

    watches.push(const FileWatchEvent(
        path: "/ws/notes/a.md", kind: FileEventKind.modify));
    await pumpEventQueue();
    expect(collected, hasLength(1));
    await sub.cancel();
  });

  test("the cooldown holds a burst to one fire", () async {
    final collected = <TriggerFire>[];
    final fires = kind().watch(
        [fileTrigger(id: "a", cooldown: const Duration(minutes: 1))], _now);
    final sub = fires.listen(collected.add);
    await pumpEventQueue();

    watches.push(const FileWatchEvent(
        path: "/ws/notes/a.md", kind: FileEventKind.modify));
    await pumpEventQueue();
    watches.push(const FileWatchEvent(
        path: "/ws/notes/b.md", kind: FileEventKind.modify));
    await pumpEventQueue();

    expect(collected, hasLength(1));
    await sub.cancel();
  });

  test("the reason words the path and the event", () async {
    final collected = <TriggerFire>[];
    final fires =
        kind().watch([fileTrigger(id: "a", paths: ["notes"])], _now);
    final sub = fires.listen(collected.add);
    await pumpEventQueue();

    watches.push(const FileWatchEvent(
        path: "/ws/notes/build.log", kind: FileEventKind.delete));
    await pumpEventQueue();

    expect(collected.single.reason, contains("build.log"));
    await sub.cancel();
  });
}