import "package:agent_chat/app/settings_sync.dart";
import "package:agent_chat/data/sync/settings_sync.dart";
import "package:agent_chat/providers.dart";
import "package:entoli_core/model/llm_provider.dart";
import "package:entoli_core/model/sync/settings_merge.dart";
import "package:file/memory.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "../harness.dart";

void main() {
  late TestApp app;
  late SettingsSyncDriver driver;

  List<LlmProviderConfig> providers() =>
      app.container.read(appSettingsProvider).llmProviders;

  setUp(() async {
    app = TestApp.create();
    final sync = SettingsSync(
      selfId: "A",
      ledger: FileSettingsLedger(MemoryFileSystem(), "/sync/settings"),
      send: (_, _) async {},
    );
    driver = app.container.read(
      Provider((ref) => SettingsSyncDriver(ref, sync)),
    );
    await app.container
        .read(appSettingsProvider.notifier)
        .upsertProvider(
          const LlmProviderConfig(
            id: "here",
            api: LlmApi.openai,
            baseUrl: "https://ollama.com/v1",
            name: "Ollama Cloud",
          ),
          setKey: "k-here",
        );
  });

  tearDown(() {
    driver.dispose();
    app.dispose();
  });

  test("a provider is an item by its name, not its id", () {
    expect(driver.read().keys, contains(providerItem("ollama cloud")));
    expect(driver.read()[providerItem("Ollama Cloud")]?["key"], "k-here");
  });

  test("the peer's entry of a name this device has is that entry", () async {
    final items = driver.read();
    await driver.write({
      ...items,
      providerItem("Ollama Cloud"): {
        ...items[providerItem("Ollama Cloud")]!,
        "key": "k-peer",
      },
    });

    expect(providers().map((p) => p.id), ["here"]);
    expect(app.secrets.providerKey("here"), "k-peer");
  });

  test("a name new here is a new entry, with an id of its own", () async {
    await driver.write({
      ...driver.read(),
      providerItem("Groq"): {
        "name": "Groq",
        "api": "openai",
        "baseUrl": "https://api.groq.com/openai/v1",
        "key": "k-groq",
      },
    });

    final names = {for (final p in providers()) p.displayName: p.id};
    expect(names.keys, ["Ollama Cloud", "Groq"]);
    expect(names["Groq"], isNot(anyOf("here", isEmpty)));
    expect(app.secrets.providerKey(names["Groq"]!), "k-groq");
  });
}
