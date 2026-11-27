import "package:entoli_core/model/llm_provider.dart";

import "../../data/builtin/llm/providers/presets.dart";

/// What the Add provider page narrows its offers to. A tag is picked one of
/// its group at a time, and every tag picked must be one the offer carries;
/// a company picked is one of those the offer may be from, an offer having
/// one company.
class ProviderFilter {
  const ProviderFilter({this.tags = const {}, this.makers = const {}});

  final Set<ProviderTag> tags;
  final Set<String> makers;

  bool get isEmpty => tags.isEmpty && makers.isEmpty;

  bool admits(LlmProvider offer) =>
      offer.tags.containsAll(tags) &&
      (makers.isEmpty || makers.contains(offer.maker));

  /// [tag] picked, in place of any other of its group, or unpicked.
  ProviderFilter toggleTag(ProviderTag tag) => ProviderFilter(
    tags: tags.contains(tag)
        ? ({...tags}..remove(tag))
        : {...tags.where((t) => t.group != tag.group), tag},
    makers: makers,
  );

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
  return [
    for (final maker in makersOf(offers))
      ...offers.where((offer) => offer.maker == maker),
  ];
}

/// The companies behind [offers], in the order they first appear.
List<String> makersOf(Iterable<LlmProvider> offers) =>
    {for (final offer in offers) offer.maker}.toList();
