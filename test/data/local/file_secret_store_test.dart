import "dart:typed_data";

import "package:agent_chat/data/local/file_secret_store.dart";
import "package:agent_chat/domain/sync/identity.dart";
import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_memory.dart";

/// The secret store Android and the web get, over a filesystem with nothing in
/// it — which is the state that matters, since the identity is written on the
/// first launch and a failure there took the app down before a frame.
void main() {
  late FileSystem fs;
  late FileSecretStore store;

  setUp(() {
    fs = newFileSystemMemory();
    store = FileSecretStore(fs, "/agent-chat");
  });

  test("writes a secret where nothing has made the directory", () async {
    await store.write("k", Uint8List.fromList([1, 2, 3]));

    expect(await store.read("k"), [1, 2, 3]);
    expect(await fs.file("/agent-chat/sync/secrets.json").exists(), isTrue);
  });

  test("a second store reads what the first wrote", () async {
    await store.write("k", Uint8List.fromList([1, 2, 3]));

    expect(await FileSecretStore(fs, "/agent-chat").read("k"), [1, 2, 3]);
  });

  test("read answers null for a key nothing was written under", () async {
    expect(await store.read("nope"), isNull);
  });

  test("delete takes a secret away", () async {
    await store.write("k", Uint8List.fromList([1, 2, 3]));
    await store.delete("k");

    expect(await FileSecretStore(fs, "/agent-chat").read("k"), isNull);
  });

  test("an identity loads on a fresh install and is stable after it", () async {
    final first = await SyncIdentity.load(store);
    final again = await SyncIdentity.load(FileSecretStore(fs, "/agent-chat"));

    expect(again.id, first.id);
    expect(again.publicKey, first.publicKey);
  });
}
