import "dart:typed_data";

import "package:agent_chat/data/sync/sync_byte_cache.dart";
import "package:flutter_test/flutter_test.dart";

/// A mirrored attachment has no disk behind it, so what this holds is all
/// there is until the next round trip — and it is bounded by bytes, since one
/// image outweighs a thousand text files.
void main() {
  late SyncByteCache cache;

  setUp(() => cache = SyncByteCache());
  tearDown(() => cache.dispose());

  Uint8List big(int megabytes) => Uint8List(megabytes * 1024 * 1024);

  test("what was put comes back", () {
    cache.put("chat", "a.png", Uint8List.fromList([1, 2, 3]));

    expect(cache.get("chat", "a.png"), [1, 2, 3]);
    expect(cache.get("chat", "b.png"), isNull);
    expect(cache.get("other", "a.png"), isNull);
  });

  test("re-putting one replaces it rather than counting it twice", () {
    cache.put("chat", "a.png", big(40));
    cache.put("chat", "a.png", big(40));
    cache.put("chat", "b.png", big(20));

    expect(cache.get("chat", "a.png"), isNotNull);
    expect(cache.get("chat", "b.png"), isNotNull);
  });

  test("past the bound the least recently read goes first", () {
    cache.put("chat", "a.png", big(30));
    cache.put("chat", "b.png", big(30));
    // Reading a puts b at the back of the queue.
    cache.get("chat", "a.png");
    cache.put("chat", "c.png", big(30));

    expect(cache.get("chat", "b.png"), isNull);
    expect(cache.get("chat", "a.png"), isNotNull);
    expect(cache.get("chat", "c.png"), isNotNull);
  });

  test("dropping a chat takes only its own bytes", () {
    cache.put("one", "a.png", Uint8List.fromList([1]));
    cache.put("two", "a.png", Uint8List.fromList([2]));

    cache.drop("one");

    expect(cache.get("one", "a.png"), isNull);
    expect(cache.get("two", "a.png"), [2]);
  });
}
