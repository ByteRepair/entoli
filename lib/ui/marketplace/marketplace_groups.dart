import "marketplace.dart";

/// The marketplace's list, grouped and filtered — the pure half of what
/// `MarketplacePage` draws, out of the widget the way the sidebar's chat
/// groups and search are.
///
/// The list draws the site's own entries first, alphabetically, and the
/// remote ones after — under the heading below, drawn only where both halves
/// have something, a heading that separates nothing being no heading at all.
const externalHeading = "External";

class MarketplaceGroups {
  const MarketplaceGroups(this.local, this.remote);

  final List<MarketplaceEntry> local;
  final List<MarketplaceEntry> remote;
}

/// [entries] — alphabetical, as the fetch leaves them — split on what makes
/// the two halves: a [MarketplaceEntry.location] names a remote entry's
/// source repository, and null is the site's own. The order within each half
/// is the order they came in.
MarketplaceGroups groupByOrigin(List<MarketplaceEntry> entries) =>
    MarketplaceGroups(
      [for (final entry in entries) if (entry.location == null) entry],
      [for (final entry in entries) if (entry.location != null) entry],
    );

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
  final needle = query.trim().toLowerCase();
  return [
    for (final entry in entries)
      if ((needle.isEmpty || _matches(entry, needle)) &&
          tagged.every(entry.tags.contains))
        entry,
  ];
}

bool _matches(MarketplaceEntry entry, String needle) =>
    entry.name.toLowerCase().contains(needle) ||
    entry.description.toLowerCase().contains(needle);

/// Every tag [entries] carry, with how many entries carry it — the tag
/// picker's rows. Alphabetical, lower-case-compared the way the list is.
List<(String, int)> tagsOf(List<MarketplaceEntry> entries) {
  final counts = <String, int>{};
  for (final entry in entries) {
    for (final tag in entry.tags) {
      counts[tag] = (counts[tag] ?? 0) + 1;
    }
  }
  final tags = counts.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [for (final tag in tags) (tag, counts[tag]!)];
}