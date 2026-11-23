import "dart:async";

import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:agent_chat/app/memories.dart";
import "package:agent_chat/data/builtin/memory/store.dart";
import "package:entoli_core/model/project.dart" show ProjectRef;
import "package:agent_chat/providers.dart";

class _Frozen extends Notifier<bool> {
  @override
  bool build() => true;

  void thaw() => state = false;
}

final _frozen = NotifierProvider<_Frozen, bool>(_Frozen.new);

/// A store whose searches are answered by hand, so two can be in flight.
class _Store implements Memories {
  int reads = 0;
  final searches = <String, Completer<List<MemoryEntry>>>{};

  @override
  Future<List<MemoryEntry>> entries() async {
    reads++;
    return const [];
  }

  @override
  Future<List<MemoryEntry>> search(String query) =>
      (searches[query] = Completer()).future;

  @override
  Future<void> add(String text) async {}
  @override
  Future<void> pin(String id) async {}
  @override
  Future<void> unpin(String id) async {}
  @override
  Future<void> delete(String id) async {}
}

MemoryEntry _entry(String text) =>
    MemoryEntry(id: text, text: text, at: DateTime.utc(2026));

void main() {
  const ProjectRef project = (device: "phone", project: null);
  late _Store store;
  late ProviderContainer container;

  setUp(() {
    store = _Store();
    container = ProviderContainer(
      overrides: [
        memoriesProvider.overrideWith((ref, _) => store),
        projectFrozenProvider.overrideWith((ref, _) => ref.watch(_frozen)),
      ],
    );
    container.listen(memoryListProvider(project), (_, _) {});
  });
  tearDown(() => container.dispose());

  Future<void> drain() => Future<void>.delayed(Duration.zero);

  test("a device coming back is read again", () async {
    await drain();
    expect(store.reads, 1);
    container.read(_frozen.notifier).thaw();
    await drain();
    expect(store.reads, 2);
  });

  test("an older search's answer does not land over a newer one", () async {
    final list = container.read(memoryListProvider(project).notifier);
    list.search("ru");
    list.search("rust");
    await drain();
    store.searches["rust"]!.complete([_entry("likes rust")]);
    await drain();
    store.searches["ru"]!.complete([_entry("rubbish")]);
    await drain();
    final shown = container.read(memoryListProvider(project));
    expect(shown.query, "rust");
    expect(shown.entries!.map((e) => e.text), ["likes rust"]);
  });
}
