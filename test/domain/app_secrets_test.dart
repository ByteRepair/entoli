import "dart:convert";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/file_secret_store.dart";
import "package:agent_chat/domain/app_secrets.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/secret_store.dart";
import "package:flutter_test/flutter_test.dart";
import "package:fs_shim/fs_memory.dart";

/// The secrets the settings pages write, over the store Android and the web
/// get, on a data directory `AppConfig.load` created — the same state the app
/// is in when the first key is stored.
void main() {
  late AppConfig config;

  setUp(() async {
    config = await AppConfig.load(newFileSystemMemory(), "/agent-chat");
  });

  AppSecrets secretsOver() => AppSecrets(FileSecretStore(config));

  test("a stored key is read back, and reads are served from the mirror", () async {
    final secrets = secretsOver();

    await secrets.setProviderKey("ollama-cloud", "sk-1");
    expect(secrets.providerKey("ollama-cloud"), "sk-1");

    // A fresh object over the same store reads the same answer: what landed
    // on disk is what the mirror was filled from.
    final again = secretsOver();
    await again.load();
    expect(again.providerKey("ollama-cloud"), "sk-1");
  });

  test("the file behind it is the store's, and no key lands in settings.json",
      () async {
    final secrets = secretsOver();

    await secrets.setProviderKey("ollama-cloud", "sk-1");
    await AppSettings(llmProviders: const []).save(config);

    final raw = await config.fs
        .file(config.fs.path.join(config.syncDir, "secrets.json"))
        .readAsString();
    // Base64 values, the store's own encoding: decode and match on that.
    final stored = {
      for (final entry in (jsonDecode(raw) as Map).cast<String, String>().entries)
        entry.key: utf8.decode(base64Decode(entry.value)),
    };
    expect(stored[providerKeysKey], contains("sk-1"));
    final settings = await config.fs.file(config.settingsFile).exists()
        ? await config.fs.file(config.settingsFile).readAsString()
        : "";
    expect(settings, isNot(contains("sk-1")));
  });

  test("null clears one entry and leaves the rest", () async {
    final secrets = secretsOver();
    await secrets.setProviderKey("a", "sk-a");
    await secrets.setProviderKey("b", "sk-b");

    await secrets.setProviderKey("a", null);

    expect(secrets.providerKey("a"), isNull);
    expect(secrets.providerKey("b"), "sk-b");

    final again = secretsOver();
    await again.load();
    expect(again.providerKey("a"), isNull);
    expect(again.providerKey("b"), "sk-b");
  });

  test("the last entry removed deletes the item, so nothing is stored at all",
      () async {
    final store = FileSecretStore(config);
    final secrets = AppSecrets(store);
    await secrets.setProviderKey("a", "sk-a");

    await secrets.setProviderKey("a", null);

    // A device with no providers holds nothing: the item is gone, not empty.
    expect(await store.read(providerKeysKey), isNull);
  });

  test("the TURN password rides its own item", () async {
    final store = FileSecretStore(config);
    final secrets = AppSecrets(store);

    await secrets.setTurnPassword("relay-pass");
    expect(secrets.turnPassword, "relay-pass");
    expect(await store.read(turnPasswordKey), utf8.encode("relay-pass"));

    final again = AppSecrets(store);
    await again.load();
    expect(again.turnPassword, "relay-pass");

    await secrets.setTurnPassword(null);
    expect(secrets.turnPassword, isNull);
    expect(await store.read(turnPasswordKey), isNull);
  });

  test("the sync identity and these secrets share one store by key", () async {
    final store = FileSecretStore(config);
    final secrets = AppSecrets(store);

    await secrets.setProviderKey("a", "sk-a");
    await secrets.setTurnPassword("p");
    expect(await store.read("identity"), isNull);
    expect(await store.read(providerKeysKey), isNotNull);
    expect(await store.read(turnPasswordKey), isNotNull);
  });
}