import "dart:typed_data";

import "package:flutter_test/flutter_test.dart";
import "package:freedesktop_secret/freedesktop_secret.dart";

import "package:agent_chat/core/platform/io/keyring_secret_store.dart";
import "package:agent_chat/domain/secret_store.dart";

void main() {
  final bytes = Uint8List.fromList([1, 2, 3]);

  test("a secret the file took while the keyring was locked is read back "
      "and moved into the keyring", () async {
    final file = _Memory()..items["k"] = bytes;
    final keyring = _Keyring();
    final store = KeyringSecretStore(file, service: () => keyring);

    expect(await store.read("k"), bytes);
    expect(keyring.items.values.single, bytes);
    expect(file.items, isEmpty, reason: "not left on disk beside the keyring");
    expect(store.encrypted, isTrue);
  });

  test("encrypted is false where every write fell through to the file",
      () async {
    final file = _Memory();
    final store =
        KeyringSecretStore(file, service: () => _Keyring(locked: true));

    await store.write("k", bytes);

    expect(file.items["k"], bytes);
    expect(store.encrypted, isFalse);
  });

  test("encrypted is false with no service at all", () async {
    final store = KeyringSecretStore(_Memory(),
        service: () => _Keyring(absent: true));
    expect(await store.read("k"), isNull);
    expect(store.encrypted, isFalse);
  });
}

class _Memory implements SecretStore {
  final items = <String, Uint8List>{};

  @override
  Future<Uint8List?> read(String key) async => items[key];

  @override
  Future<void> write(String key, Uint8List value) async => items[key] = value;

  @override
  Future<void> delete(String key) async => items.remove(key);

  @override
  bool get encrypted => false;
}

class _Keyring implements SecretServiceClient {
  _Keyring({this.locked = false, this.absent = false});

  final bool locked;
  final bool absent;
  final items = <String, Uint8List>{};

  @override
  Future<void> initialize() async {
    if (absent) throw Exception("no service");
  }

  @override
  Future<SecretItem?> lookupSecret({
    required Map<String, String> attributes,
    LookupSecretDuplicateStrategy duplicateStrategy =
        LookupSecretDuplicateStrategy.throwException,
    Object? collection,
  }) async {
    if (locked) throw Exception("locked");
    final value = items[attributes["kind"]];
    if (value == null) return null;
    return SecretItem(
      attributes: attributes,
      secretBytes: value,
      contentType: "application/octet-stream",
      label: "",
      created: DateTime(2026),
      modified: DateTime(2026),
    );
  }

  @override
  Future<void> storeSecret({
    required Map<String, String> attributes,
    required Uint8List secretBytes,
    required String contentType,
    required String label,
    required bool replace,
    Object? collection,
  }) async {
    if (locked) throw Exception("locked");
    items[attributes["kind"]!] = secretBytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
