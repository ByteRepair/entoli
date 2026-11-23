import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/log.dart";
import "package:entoli_core/model/date_words.dart" show shortDate;
import "package:entoli_core/model/project.dart" show ProjectRef;

import "../data/builtin/memory/store.dart";
import "../providers.dart";

/// What the memories page shows: the store's entries for [query], null
/// until the first read lands.
class MemoryList {
  const MemoryList({this.entries, this.query = ""});

  final List<MemoryEntry>? entries;
  final String query;
}

/// A memory's age in words: the year goes with it once it is no longer this
/// one, because a memory outlives the week reminders are planned for.
String memoryWhen(DateTime at) {
  final day = shortDate(at);
  return at.year == DateTime.now().year ? day : "$day ${at.year}";
}

/// Where a memory came from, as its row says.
String memoryByline(MemoryEntry entry) =>
    "${memoryWhen(entry.at)} · "
    "${entry.chat == null ? "added by you" : "kept by the agent"}";

/// A project's memories as the page browses them: a search that matches the
/// way a turn's recall does, and adding, pinning and deleting. A paired
/// device's store is read there, and read again when it comes back.
class MemoryListController extends Notifier<MemoryList> {
  MemoryListController(this.project);

  final ProjectRef project;
  int _generation = 0;
  String _query = "";

  Memories get _store => ref.read(memoriesProvider(project));

  @override
  MemoryList build() {
    // Back is read again rather than trusted.
    ref.listen(projectFrozenProvider(project), (was, now) {
      if (was == true && !now) _reload();
    });
    _reload();
    return const MemoryList();
  }

  void search(String query) {
    _query = query.trim();
    _reload();
  }

  /// A search types faster than the store answers, and an old answer must
  /// not land under a newer query.
  Future<void> _reload() async {
    final generation = ++_generation;
    final query = _query;
    List<MemoryEntry>? entries;
    try {
      // Newest first as the store holds them read back; a search best first,
      // the order the recall would have offered them in.
      entries = query.isEmpty
          ? (await _store.entries()).reversed.toList()
          : await _store.search(query);
    } catch (e) {
      // A paired device gone: what was drawn stays.
      logFailure("memory", "could not read memories", e);
    }
    if (!ref.mounted || generation != _generation) return;
    state = MemoryList(
      entries: entries ?? state.entries ?? const [],
      query: query,
    );
  }

  /// Null where it was added, else what to say.
  Future<String?> add(String text) async {
    try {
      await _store.add(text.trim());
    } catch (e) {
      logFailure("memory", "could not add a memory", e);
      return "The memory could not be saved.";
    }
    await _reload();
    return null;
  }

  Future<String?> togglePin(MemoryEntry entry) async {
    final store = _store;
    try {
      if (entry.pinned) {
        await store.unpin(entry.id);
      } else {
        // Counted over the whole store: a search is a window, and a pin made
        // inside it must not slip past the limit the full list shows.
        final shown = state.query.isEmpty ? state.entries : null;
        final all = shown ?? await store.entries();
        final pinned = all.where((e) => e.pinned).length;
        if (pinned >= pinnedLimit) {
          return "Four is the most that can be pinned.";
        }
        await store.pin(entry.id);
      }
    } catch (e) {
      logFailure("memory", "could not change a pin", e);
      return "The pin could not be changed.";
    }
    await _reload();
    return null;
  }

  Future<String?> delete(MemoryEntry entry) async {
    try {
      await _store.delete(entry.id);
    } catch (e) {
      logFailure("memory", "could not delete a memory", e);
      return "The memory could not be deleted.";
    }
    await _reload();
    return null;
  }
}

final memoryListProvider = NotifierProvider.autoDispose
    .family<MemoryListController, MemoryList, ProjectRef>(
      MemoryListController.new,
    );
