import "package:agent_chat/app/settings/provider_edit.dart";
import "package:agent_chat/data/builtin/llm/providers/presets.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  const entry = LlmProviderConfig(
    id: "p",
    api: LlmApi.openai,
    baseUrl: "http://localhost:1234/v1",
    name: "Mine",
  );

  LlmProvider preset(String name) => [
    ...llmProviderPresets,
    ...cliProviderPresets,
  ].firstWhere((p) => p.displayName == name);

  ProviderEdit edit({
    LlmProviderConfig? provider,
    LlmProvider? from,
    String? stored,
    bool Function(String)? taken,
  }) => ProviderEdit(
    provider,
    preset: from,
    id: provider?.id ?? "new",
    nameTaken: taken ?? (_) => false,
    storedKey: stored,
  );

  test("a preset falls back to its own name and address", () {
    final e = edit(from: preset("Ollama Cloud"))..key = "sk-ollama";
    expect(e.title, "Connect Ollama Cloud");
    expect(e.canSave, isTrue);
    final made = e.draft;
    expect(made.config.displayName, "Ollama Cloud");
    expect(made.config.baseUrl, "https://ollama.com/v1");
    expect(made.config.catalogId, "ollama-cloud");
    expect(made.config.id, "new");
    expect(made.setKey, "sk-ollama");
  });

  test("a preset already configured needs a name of its own", () {
    final e = edit(
      from: preset("Ollama Cloud"),
      taken: (name) => name == "Ollama Cloud",
    );
    expect(e.canSave, isFalse);
    expect(e.nameError, "Another provider is called Ollama Cloud");
    e.name = "Ollama work";
    expect(e.canSave, isTrue);
    expect(e.nameError, isNull);
  });

  test("a program keeps its environment and no key", () {
    final e = edit(from: preset("Claude CLI"))..env = {"A": "1"};
    expect(e.api, LlmApi.claudeCli);
    final made = e.draft;
    expect(made.config.id, "new");
    expect(made.config.env, {"A": "1"});
    expect(made.setKey, isNull);
  });

  test("an empty key keeps the stored one, and Remove removes it", () {
    final e = edit(provider: entry, stored: "sk-1");
    expect(e.title, "Edit Mine");
    expect(e.draft.setKey, isNull);
    e.removeKey = true;
    expect(e.draft.setKey, "");
    e.key = "sk-2";
    expect(e.draft.setKey, "sk-2");
  });

  test("over no stored key, an empty field clears", () {
    expect(edit(provider: entry).draft.setKey, "");
  });

  test("one typed in by hand needs a name and an address", () {
    final e = edit();
    expect(e.title, "Add provider");
    expect(e.canSave, isFalse);
    e.name = "Box";
    expect(e.canSave, isFalse);
    e.baseUrl = "http://box/v1";
    expect(e.canSave, isTrue);
  });

  test("an edit keeps its id", () {
    final e = edit(provider: entry)..name = "Renamed";
    expect(e.draft.config.id, "p");
    expect(e.draft.config.displayName, "Renamed");
  });

  test("a refused key is checked, an unanswered one is not a no", () async {
    final e = edit(from: preset("Ollama Cloud"))..key = "sk";
    expect(await checkProviderKey((_, _) async => false, e.draft), isFalse);
    expect(
      await checkProviderKey((_, _) async => throw Exception("down"), e.draft),
      isNull,
    );
    expect(
      await checkProviderKey(
        (_, _) async => false,
        edit(provider: entry).draft,
      ),
      isNull,
    );
  });
}
