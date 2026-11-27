import "package:entoli_core/model/llm_provider.dart";

import "../../data/builtin/llm/providers/presets.dart";

/// What the Add provider page narrows its offers to. Every tag picked must be
/// one the offer carries, so the filter only ever tightens; a company picked
/// is one of those the offer may be from, an offer having one company.
class ProviderFilter {
  const ProviderFilter({this.tags = const {}, this.makers = const {}});

  final Set<ProviderTag> tags;
  final Set<String> makers;

  bool get isEmpty => tags.isEmpty && makers.isEmpty;

  bool admits(LlmProvider offer) =>
      offer.tags.containsAll(tags) &&
      (makers.isEmpty || makers.contains(offer.maker));

  ProviderFilter toggleTag(ProviderTag tag) =>
      ProviderFilter(tags: _toggled(tags, tag), makers: makers);

  ProviderFilter toggleMaker(String maker) =>
      ProviderFilter(tags: tags, makers: _toggled(makers, maker));

  static Set<T> _toggled<T>(Set<T> set, T item) =>
      set.contains(item) ? ({...set}..remove(item)) : {...set, item};
}

/// Every provider the page offers — the presets, and the programs this
/// platform can run — with each company's offers side by side.
List<LlmProvider> providerOffers() {
  final offers = <LlmProvider>[
    ...llmProviderPresets,
    ...cliProviderPresets.where((cli) => cli.supported),
  ];
  final order = makersOf(offers);
  return offers
    ..sort((a, b) => order.indexOf(a.maker).compareTo(order.indexOf(b.maker)));
}

/// The companies behind [offers], in the order they first appear.
List<String> makersOf(Iterable<LlmProvider> offers) =>
    {for (final offer in offers) offer.maker}.toList();
