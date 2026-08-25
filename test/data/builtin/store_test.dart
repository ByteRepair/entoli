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

  test("a manual add carries no chat", () async {
    final entry = await store.add("typed by hand");
    expect(entry.chat, isNull);
  });

  test("add trims the text and refuses an empty one", () async {
    final entry = await store.add("  padded  ");
    expect(entry.text, "padded");
    expect(() => store.add("   "), throwsArgumentError);
  });

  test("a tombstone removes the memory, a later memory survives", () async {
    final a = await store.add("first memory");
    final b = await store.add("second memory");
    await store.delete(a.id);

    final entries = await store.entries();
    expect([for (final e in entries) e.id], [b.id]);
  });

  test("a tombstone for a memory that is not there changes nothing", () async {
    await store.add("a memory");
    await store.delete("no-such-id");
    expect(await store.entries(), hasLength(1));
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
    test("a word only one memory carries recalls it", () async {
      await store.add("the build needs the flutter toolbox");
      await store.add("unrelated notes about the weather");

      final hits = await store.search("flutter");
      expect(hits, hasLength(1));
      expect(hits.single.text, contains("toolbox"));
    });

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

    test("no match recalls nothing", () async {
      await store.add("a memory about lighthouses");
      expect(await store.search("completely different words"), isEmpty);
    });

    test("single-letter words are not indexed", () async {
      await store.add("an i and a b in a sentence");
      expect(await store.search("i b"), isEmpty);
    });
  });

  group("tokenize", () {
    test("lowercases and keeps runs of letters and digits", () {
      // The 3 in 3.22 is one letter long, so it is out.
      expect(tokenize("Flutter 3.22, and Dart!"), ["flutter", "22", "and", "dart"]);
    });

    test("drops words of one letter", () {
      expect(tokenize("a b an io"), ["an", "io"]);
    });
  });

  group("renderRecall", () {
    test("empty where there is nothing", () {
      expect(renderRecall(const []), isEmpty);
    });

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
}
