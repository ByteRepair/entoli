import "../../domain/chat_search.dart" show searchNeedle;
import "marketplace.dart";

// The marketplace's list, grouped and filtered: the pure half of what
// `MarketplaceAppPage` draws.

/// One ext manifest's entries under the name the site gives them.
class MarketplaceCollection {
  MarketplaceCollection({
    required this.slug,
    required this.name,
    required this.summary,
    required this.members,
  });

  final String slug;
  final String name;
  final String summary;
  final List<MarketplaceEntry> members;

  /// Whether every member is another repository's.
  late final bool external = members.every((member) => member.external);

  late final String _lowerName = name.toLowerCase();
  late final String _lowerSummary = summary.toLowerCase();
}

/// [entries] split into the front page's and the collections'. An entry is a
/// member of the first record listing its key; everything else is the
/// front's, in the order it came in. Collections are alphabetical by name,
/// members in the order they came in, and one left with no members (a key
/// the index no longer has) is dropped.
(List<MarketplaceEntry>, List<MarketplaceCollection>) groupIntoCollections(
  List<MarketplaceEntry> entries,
  Map<String, CollectionRecord> records,
) {
  final owner = <String, String>{};
  for (final MapEntry(key: slug, value: record) in records.entries) {
    for (final key in record.members) {
      owner.putIfAbsent(key, () => slug);
    }
  }
  final front = <MarketplaceEntry>[];
  final members = <String, List<MarketplaceEntry>>{};
  for (final entry in entries) {
    if (owner[entry.slug] case final slug?) {
      (members[slug] ??= []).add(entry);
    } else {
      front.add(entry);
    }
  }
  final collections = [
    for (final MapEntry(key: slug, value: list) in members.entries)
      MarketplaceCollection(
        slug: slug,
        name: records[slug]!.name,
        summary: records[slug]!.summary,
        members: list,
      ),
  ]..sort((a, b) => a._lowerName.compareTo(b._lowerName));
  return (front, collections);
}

/// The collections whose name or summary [query] matches; all of them for an
/// empty query.
List<MarketplaceCollection> collectionsMatching(
  List<MarketplaceCollection> collections,
  String query,
) {
  final needle = searchNeedle(query);
  return [
    for (final collection in collections)
      if (needle.isEmpty ||
          collection._lowerName.contains(needle) ||
          collection._lowerSummary.contains(needle))
        collection,
  ];
}

/// The entries a tab's search and tag ticks pick out, in the order they came
/// in. [query] is matched against the name and the description alike — the
/// list re-orders nothing for it, a description-only match keeping the
/// alphabetical row it belongs in. [tagged] is the intersection: an entry
/// passes carrying every tag ticked. An empty query and no ticks are no
/// filters, and the whole list comes through.
List<MarketplaceEntry> entriesMatching(
  List<MarketplaceEntry> entries,
  String query,
  Set<String> tagged,
) {
  final needle = searchNeedle(query);
  return [
    for (final entry in entries)
      if ((needle.isEmpty || _matches(entry, needle)) &&
          tagged.every(entry.tags.contains))
        entry,
  ];
}

bool _matches(MarketplaceEntry entry, String needle) =>
    entry.lowerName.contains(needle) || entry.lowerDescription.contains(needle);

/// Every tag [entries] carry, with how many entries carry it — the tag
/// picker's rows. Alphabetical, lower-case-compared the way the list is. A
/// tag every entry carries filters nothing, so it is left out.
List<(String, int)> tagsOf(List<MarketplaceEntry> entries) {
  final counts = <String, int>{};
  for (final entry in entries) {
    for (final tag in entry.tags) {
      counts[tag] = (counts[tag] ?? 0) + 1;
    }
  }
  final tags = counts.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [
    for (final tag in tags)
      if (counts[tag]! < entries.length) (tag, counts[tag]!),
  ];
}
