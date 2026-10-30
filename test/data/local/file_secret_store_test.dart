import "dart:io";
import "dart:typed_data";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/file_secret_store.dart";
import "package:agent_chat/domain/sync/identity.dart";
import "package:flutter_test/flutter_test.dart";

import "../../harness.dart";

/// The secret store Android gets, over a data directory this launch
/// created — which is the state that matters, since the identity is written on
/// the first launch and a failure there took the app down before a frame.
void main() {
  late AppConfig config;
  late FileSecretStore store;

  setUp(() async {
    config = await loadedTempConfig();
    store = FileSecretStore(config);
  });

  Uint8List bytes() => Uint8List.fromList([1, 2, 3]);

  test(
    "writes a secret on a data directory nothing has written to yet",
    () async {
      await store.write("k", bytes());

      expect(await store.read("k"), bytes());
      expect(File("${config.dataDir}/sync/secrets.json").existsSync(), isTrue);
    },
  );

  test("a second store reads what the first wrote", () async {
    await store.write("k", bytes());

    expect(await FileSecretStore(config).read("k"), bytes());
  });

  test("two first writes at once both land", () async {
    await Future.wait([store.write("a", bytes()), store.write("b", bytes())]);

    final again = FileSecretStore(config);
    expect(await again.read("a"), bytes());
    expect(await again.read("b"), bytes());
  });

  test("writes in flight land in call order", () async {
    await store.write("seed", bytes());
    await Future.wait([
      store.write("a", Uint8List.fromList([1])),
      store.write("b", bytes()),
      store.write("a", Uint8List.fromList([2])),
    ]);

    final again = FileSecretStore(config);
    expect(await again.read("a"), [2]);
    expect(await again.read("b"), bytes());
  });

  test("read answers null for a key nothing was written under", () async {
    expect(await store.read("nope"), isNull);
  });

  test("delete takes a secret away", () async {
    await store.write("k", bytes());
    await store.delete("k");

    expect(await FileSecretStore(config).read("k"), isNull);
  });

  test("an identity loads on a fresh install and is stable after it", () async {
    final first = await SyncIdentity.load(store);
    final again = await SyncIdentity.load(FileSecretStore(config));

    expect(again.id, first.id);
    expect(again.publicKey, first.publicKey);
  });
}
