import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_io.dart" show fileSystemIo;
import "package:path/path.dart" as p;

import "package:agent_chat/data/builtin/memory/store.dart";

void main() {
  late Directory tmp;
  late String dir;
  late MemoryStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync("memory_store_test_");
    dir = p.join(tmp.path, "memory");
    store = MemoryStore(fileSystemIo, dir);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test("an empty store has no entries and answers nothing", () async {
    expect(await store.entries(), isEmpty);
    expect(await store.search("flutter"), isEmpty);
  });

  test("add writes a memory and entries reads it back", () async {
    final entry = await store.add("the user prefers tabs", chat: "chat-1");

    final entries = await store.entries();
    expect(entries, hasLength(1));
    expect(entries.single.id, entry.id);
    expect(entries.single.text, "the user prefers tabs");
    expect(entries.single.chat, "chat-1");
  });

  test("add trims the text and refuses an empty one", () async {
    final entry = await store.add("  padded  ");
    expect(entry.text, "padded");
    expect(() => store.add("   "), throwsArgumentError);
  });

  test("a torn last line ends the replay, the whole lines stand", () async {
    await store.add("a whole memory");
    File(p.join(dir, "memories.jsonl"))
        .writeAsStringSync('{"t":"m","id":"torn",', mode: FileMode.append);

    final entries = await store.entries();
    expect(entries, hasLength(1));
    expect(entries.single.text, "a whole memory");
  });

  test("a log written behind the store's back is picked up", () async {
    await store.add("flutter is here");
    File(p.join(dir, "memories.jsonl")).writeAsStringSync(
      "${jsonEncode({
        "t": "m",
        "id": "side",
        "text": "kotlin was written to the log directly",
        "at": "2026-01-01T00:00:00.000Z",
      })}\n",
      mode: FileMode.append,
    );

    expect((await store.entries()), hasLength(2));
    expect((await store.search("kotlin")), hasLength(1));
  });

  group("search", () {
    test("a word every memory carries recalls nothing", () async {
      await store.add("the first note");
      await store.add("the second note");
      await store.add("the third note");

      expect(await store.search("the"), isEmpty);
    });

    test("two matching words beat one, and the cap is five", () async {
      for (var i = 0; i < 7; i++) {
        await store.add("word$i only appears here");
      }
      await store.add("word0 and word1 appear together");

      final hits = await store.search("word0 word1 word2 word3 word4 word5 word6");
      // word0 and word1 are each in two memories, so they score a half a
      // piece and their memories sit under the bar; the five single-word
      // memories and the double match all score 1, and the cap trims the
      // six to five, newest first among ties.
      expect(hits, hasLength(5));
      expect(hits.first.text, contains("together"));
    });

    test("single-letter words are not indexed", () async {
      await store.add("an i and a b in a sentence");
      expect(await store.search("i b"), isEmpty);
    });
  });

  group("tokenize", () {
    test("lowercases and keeps runs of letters and digits", () {
      expect(tokenize("Flutter 3.22, and Dart!"), ["flutter", "22", "and", "dart"]);
    });
  });

  group("update", () {
    test("the old position in the list stands, the text moves", () async {
      final first = await store.add("first");
      await store.add("second");
      await store.update(first.id, "first, revised");

      final entries = await store.entries();
      expect([for (final e in entries) e.text], ["first, revised", "second"]);
    });

    test("an update to a missing id is a new memory under that id", () async {
      await store.update("no-such-id", "a fact with no predecessor");
      final entries = await store.entries();
      expect(entries, hasLength(1));
      expect(entries.single.id, "no-such-id");
    });

    test("an empty update is refused", () async {
      final entry = await store.add("a memory");
      expect(() => store.update(entry.id, "  "), throwsArgumentError);
      expect(await store.entries(), hasLength(1));
    });
  });

  group("pinning", () {
    test("the last pin or unpin stands", () async {
      final entry = await store.add("toggle me");
      await store.pin(entry.id);
      await store.unpin(entry.id);
      await store.pin(entry.id);
      expect((await store.entries()).single.pinned, isTrue);
    });

    test("a pin for a memory that is not there changes nothing", () async {
      await store.pin("no-such-id");
      await store.add("a memory");
      expect(await store.entries(), hasLength(1));
      expect((await store.entries()).single.pinned, isFalse);
    });

    test("a pin does not keep a tombstoned memory alive", () async {
      final entry = await store.add("doomed");
      await store.pin(entry.id);
      await store.delete(entry.id);
      expect(await store.entries(), isEmpty);
    });
  });

  group("maintain", () {
    test("drops, replacements and new ones all land", () async {
      final keep = await store.add("keep this");
      final drop = await store.add("drop this");
      final result = await store.maintain(
        delete: [drop.id, "no-such-id"],
        replaces: {keep.id: "keep this, revised"},
        add: ["a brand new fact"],
        chat: "chat-9",
      );

      expect(result, (added: 1, updated: 1, deleted: 1));
      final entries = await store.entries();
      expect(entries, hasLength(2));
      expect(entries.singleWhere((e) => e.id == keep.id).text,
          "keep this, revised");
      expect(entries.singleWhere((e) => e.id == keep.id).chat, "chat-9");
      expect(
          entries.any((e) => e.text == "a brand new fact"), isTrue);
      // And the search index follows what the batch landed: the added memory
      // is recallable, the revised one by its new text.
      expect((await store.search("brand")).map((e) => e.text),
          ["a brand new fact"]);
    });

    test("a replacement of a missing id lands as a new memory", () async {
      final result = await store.maintain(replaces: {"no-such-id": "fresh fact"});
      expect(result, (added: 1, updated: 0, deleted: 0));
      final entries = await store.entries();
      expect(entries, hasLength(1));
      expect(entries.single.text, "fresh fact");
      expect(entries.single.id, isNot("no-such-id"));
    });

    test("empty texts are skipped and an empty batch changes nothing",
        () async {
      await store.add("a memory");
      final result = await store.maintain(
        delete: [],
        replaces: {"no-such-id": "   "},
        add: ["", "  "],
      );
      expect(result, (added: 0, updated: 0, deleted: 0));
      expect(await store.entries(), hasLength(1));
    });
  });

  group("renderIndex", () {
    // Empty where there is nothing — the caller sends no section then; the
    // same input answers the recall render the same way.
    test("empty where there is nothing", () {
      expect(renderIndex(const []), isEmpty);
      expect(renderRecall(const []), isEmpty);
    });

    test("one line per memory, newest first", () async {
      await store.add("the older note");
      await store.add("the newer note");
      final block = renderIndex(await store.entries());
      expect(block, "- the newer note\n- the older note");
    });

    test("a long line is cut and the block has a ceiling", () {
      final long = List.filled(20, "a memory long enough to matter").join(" ");
      final entries = [
        for (var i = 0; i < 20; i++)
          MemoryEntry(id: "id$i", text: long, at: DateTime(2026)),
      ];
      final block = renderIndex(entries);
      expect(block, contains("..."));
      expect(block.length, lessThan(indexBlockChars + indexEntryChars + 10));
    });
  });

  group("renderRecall", () {
    test("one line per memory", () async {
      await store.add("first memory");
      await store.add("second memory");
      final block = renderRecall(await store.entries());
      expect(block, contains("- first memory"));
      expect(block, contains("- second memory"));
      expect(block, isNot(contains("\n\n")));
    });

    test("a long memory is cut, and the block has a ceiling", () {
      final long = List.filled(20, "a memory long enough to matter").join(" ");
      expect(long.length, greaterThan(recallEntryChars));
      final entries = [
        for (var i = 0; i < 20; i++)
          MemoryEntry(id: "id$i", text: long, at: DateTime(2026)),
      ];
      final block = renderRecall(entries);
      expect(block, contains("..."));
      // The ceiling plus at most the one entry that tipped it over.
      expect(block.length, lessThan(recallBlockChars + recallEntryChars + 10));
    });
  });

  group("renderPinned", () {
    test("the pinned memories in full, newest first, the rest out",
        () async {
      final older = await store.add("an older pinned memory");
      await store.pin(older.id);
      await store.add("a plain memory");
      final newer = await store.add("a newer pinned memory");
      await store.pin(newer.id);

      final block = renderPinned(await store.entries());
      expect(block, "- a newer pinned memory\n- an older pinned memory");
    });

    test("cut at the limit, the newest are the ones that fit", () {
      final entries = [
        for (var i = 0; i < pinnedLimit + 2; i++)
          MemoryEntry(
              id: "id$i",
              text: "memory $i",
              at: DateTime(2026, 1, 1, i),
              pinned: true),
      ];
      final block = renderPinned(entries);
      expect(block.split("\n"), hasLength(pinnedLimit));
      expect(block, isNot(contains("memory 0")));
      expect(block, isNot(contains("memory 1")));
      expect(block, contains("memory ${pinnedLimit + 1}"));
    });

    test("empty where nothing is pinned", () async {
      await store.add("a plain memory");
      expect(renderPinned(await store.entries()), isEmpty);
    });
  });

  group("consolidation", () {
    test("the stamp is nothing until it is written, then the time it was given",
        () async {
      expect(await store.lastConsolidated(), isNull);
      final then = DateTime.utc(2026, 1, 2, 3);
      await store.stampConsolidated(then);
      expect(await store.lastConsolidated(), then);
    });

    test("a stamp that will not parse reads as never", () async {
      final directory = Directory(dir);
      directory.createSync(recursive: true);
      File(p.join(dir, "consolidated")).writeAsStringSync("torn");
      expect(await store.lastConsolidated(), isNull);
    });

    test("the pass is shown every entry in full, newest first", () async {
      final first = await store.add("an older memory");
      final newer = await store.add("a newer memory");
      final block = renderConsolidation(await store.entries());
      expect(block, "- [${newer.id}] a newer memory\n- [${first.id}] an older memory");
    });

    test("a grown store is cut at the ceiling, the oldest out", () {
      final n = consolidationMaxEntries + 10;
      final entries = [
        for (var i = 0; i < n; i++)
          MemoryEntry(id: "id$i", text: "memory $i", at: DateTime(2026)),
      ];
      final block = renderConsolidation(entries);
      expect(block, isNot(contains("- [id${n - consolidationMaxEntries - 1}]")));
      expect(block, contains("- [id${n - consolidationMaxEntries}]"));
      expect(block.split("\n"), hasLength(consolidationMaxEntries));
    });
  });
}
