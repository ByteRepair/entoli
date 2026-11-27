import "package:agent_chat/app/settings/provider_filter.dart";
import "package:entoli_core/model/llm_provider.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  final offers = providerOffers();
  List<String> shown(ProviderFilter filter) => [
    for (final offer in offers)
      if (filter.admits(offer)) offer.displayName,
  ];

  test("nothing picked shows every offer", () {
    expect(shown(const ProviderFilter()), hasLength(offers.length));
  });

  test("tags narrow together: no free tier is private", () {
    const free = ProviderFilter(tags: {ProviderTag.free});
    expect(shown(free), containsAll(["Google Gemini", "Mistral"]));
    expect(shown(free), isNot(contains("Groq")));
    expect(shown(free.toggleTag(ProviderTag.private)), isEmpty);
  });

  test("a model run here is private, and neither paid nor free", () {
    const private = ProviderFilter(tags: {ProviderTag.private});
    expect(shown(private), containsAll(["Ollama (local)", "Groq"]));
    for (final tag in [ProviderTag.paid, ProviderTag.free]) {
      expect(shown(private.toggleTag(tag)), isNot(contains("Ollama (local)")));
    }
  });

  test("an opt-in to training is not private, and not opt-out", () {
    List<String> tagged(ProviderTag tag) => shown(ProviderFilter(tags: {tag}));
    expect(
      tagged(ProviderTag.optInCollection),
      containsAll(["Anthropic", "OpenAI", "OpenRouter"]),
    );
    expect(
      tagged(ProviderTag.optOutCollection),
      containsAll(["Google Gemini", "Mistral"]),
    );
    for (final api in ["Anthropic", "OpenAI"]) {
      expect(tagged(ProviderTag.private), isNot(contains(api)));
      expect(tagged(ProviderTag.optOutCollection), isNot(contains(api)));
    }
  });

  test("companies widen among themselves, and a toggle undoes itself", () {
    final ollama = const ProviderFilter().toggleMaker("Ollama");
    expect(shown(ollama), ["Ollama Cloud", "Ollama (local)"]);
    expect(shown(ollama.toggleMaker("Groq")), hasLength(3));
    expect(ollama.toggleMaker("Ollama").isEmpty, isTrue);
  });

  test("a company's offers sit side by side", () {
    final makers = [for (final offer in offers) offer.maker];
    for (final maker in makersOf(offers)) {
      final first = makers.indexOf(maker);
      final last = makers.lastIndexOf(maker);
      expect(makers.sublist(first, last + 1).toSet(), {maker});
    }
  });
}
