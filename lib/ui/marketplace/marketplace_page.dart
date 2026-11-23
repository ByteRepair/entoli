import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/marketplace/groups.dart";
import "../../app/marketplace/marketplace.dart";
import "../../app/marketplace/preview.dart";
import "package:entoli_chat/domain/chat_search.dart" show searchNeedle;
import "package:entoli_chat/domain/models.dart";
import "../widgets/nothing.dart";
import "package:entoli_chat/ui/widgets/page_bar.dart";
import "../widgets/search_field.dart";
import "../widgets/section_header.dart";
import "marketplace_entry_preview.dart";
import "marketplace_rows.dart";
import "marketplace_tags.dart";
import "unreachable.dart";

/// Open the marketplace: the sidebar's tile and the app menu.
void openMarketplace(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const MarketplacePage()));

/// The kinds that are tabs, in tab order.
const _tabs = [CompletionKind.skill, CompletionKind.agent];

/// The marketplace: what the site ships, Skills or Agents over its tabs.
/// Each tab lists its collections, then every entry in none; the search box
/// over the tabs matches names and descriptions and reaches into the
/// collections, and the filter icon ticks the tab's tags. See
/// `lib/app/marketplace/AGENTS.md`.
class MarketplacePage extends ConsumerStatefulWidget {
  const MarketplacePage({super.key});

  @override
  ConsumerState<MarketplacePage> createState() => _MarketplacePageState();
}

class _MarketplacePageState extends ConsumerState<MarketplacePage>
    with SingleTickerProviderStateMixin {
  late final _tabController = TabController(length: _tabs.length, vsync: this)
    ..addListener(() => setState(() {}));
  final _search = TextEditingController();

  /// The tabs listen to this rather than the page rebuilding on a keystroke.
  final _query = ValueNotifier("");

  /// The tags ticked per tab, kept here because the tabs outlive the picker
  /// that ticks them.
  final _tagged = {for (final kind in _tabs) kind: ValueNotifier(<String>{})};

  @override
  void initState() {
    super.initState();
    _search.addListener(() => _query.value = _search.text);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _search.dispose();
    _query.dispose();
    for (final ticked in _tagged.values) {
      ticked.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kind = _tabs[_tabController.index];
    final listing = ref.watch(marketplaceEntriesProvider(kind)).value;
    final tags = listing == null
        ? const <(String, int)>[]
        : tagsOf(grouped(listing).$1);
    return Scaffold(
      appBar: PageBar(
        title: "Marketplace",
        actions: [
          // The tags filter the front page's entries alone; a list no tag
          // narrows has nothing to filter by.
          if (tags.isNotEmpty)
            PageAction.icon(
              icon: Icons.filter_list,
              label: "Filter by tag",
              onPressed: () => openTagPicker(context, tags, _tagged[kind]!),
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [for (final kind in _tabs) Tab(text: kind.label)],
        ),
      ),
      body: Column(
        children: [
          SearchField(
            controller: _search,
            hint: "Search",
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                for (final kind in _tabs)
                  _Tab(kind: kind, query: _query, tagged: _tagged[kind]!),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// [tags], ticked into [ticked].
void openTagPicker(
  BuildContext context,
  List<(String, int)> tags,
  ValueNotifier<Set<String>> ticked,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => MarketplaceTagPickerPage(tags: tags, ticked: ticked),
  ),
);

/// A tab keeps itself mounted across a flip: without it the autoDispose
/// list under the tab left is disposed, and every flip fetched it again.
class _Tab extends ConsumerStatefulWidget {
  const _Tab({required this.kind, required this.query, required this.tagged});

  final CompletionKind kind;
  final ValueNotifier<String> query;
  final ValueNotifier<Set<String>> tagged;

  @override
  ConsumerState<_Tab> createState() => _TabState();
}

class _TabState extends ConsumerState<_Tab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final kind = widget.kind;
    return switch (ref.watch(marketplaceEntriesProvider(kind))) {
      AsyncValue(hasValue: true, :final value?) => ListenableBuilder(
        listenable: Listenable.merge([widget.query, widget.tagged]),
        builder: (context, _) =>
            _lists(context, value, widget.query.value, widget.tagged.value),
      ),
      AsyncValue(:final error?) => Unreachable(
        detail: "$error",
        onRetry: () => ref.invalidate(marketplaceEntriesProvider(kind)),
      ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }

  Widget _lists(
    BuildContext context,
    MarketplaceListing listing,
    String query,
    Set<String> tagged,
  ) {
    final kind = widget.kind;
    if (listing.entries.isEmpty) {
      return Nothing("The marketplace lists no ${kind.folder} yet.");
    }
    final (front, collections) = grouped(listing);
    final shownFront = entriesMatching(front, query, tagged);
    void open(MarketplaceCollection collection) => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            MarketplaceCollectionPage(kind: kind, collection: collection),
      ),
    );
    List<Widget> cards(List<MarketplaceCollection> shown) => [
      _heading("Collections", shown.length),
      SliverToBoxAdapter(
        child: CollectionCards(kind: kind, collections: shown, onOpen: open),
      ),
    ];
    if (searchNeedle(query).isEmpty) {
      return CustomScrollView(
        slivers: [
          if (collections.isNotEmpty) ...cards(collections),
          if (front.isNotEmpty) ...[
            // A heading that separates nothing is no heading at all.
            if (collections.isNotEmpty) _heading(kind.label, shownFront.length),
            ..._entries(kind, shownFront),
          ],
        ],
      );
    }
    final matched = collectionsMatching(collections, query);
    final members = [
      for (final collection in collections)
        if (entriesMatching(collection.members, query, const {}) case final hits
            when hits.isNotEmpty)
          (collection, hits),
    ];
    if (shownFront.isEmpty && matched.isEmpty && members.isEmpty) {
      return Nothing("Nothing matches \"${query.trim()}\".");
    }
    return CustomScrollView(
      slivers: [
        if (matched.isNotEmpty) ...cards(matched),
        // Kept while a tag is ticked, so the ticks can be undone.
        if (shownFront.isNotEmpty || tagged.isNotEmpty) ...[
          _heading(kind.label, shownFront.length),
          ..._entries(kind, shownFront),
        ],
        for (final (collection, hits) in members) ...[
          _heading(collection.name, hits.length),
          ..._entries(kind, hits),
        ],
      ],
    );
  }
}

/// A heading with how many sit under it.
Widget _heading(String heading, int n) =>
    SliverToBoxAdapter(child: SectionHeader("$heading · $n"));

/// [entries] as rows, or a line saying none passed the filters.
List<Widget> _entries(CompletionKind kind, List<MarketplaceEntry> entries) => [
  if (entries.isEmpty)
    const SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Nothing("Nothing matches here."),
      ),
    )
  else
    SliverList.builder(
      itemCount: entries.length,
      itemBuilder: (context, i) => EntryTile(
        entry: entries[i],
        kind: kind,
        onTap: () =>
            openMarketplaceEntry(context, kind: kind, entry: entries[i]),
      ),
    ),
];

/// One collection's members, searched and filtered by tag on their own.
/// Handed the members already fetched, so it fetches nothing.
class MarketplaceCollectionPage extends StatefulWidget {
  const MarketplaceCollectionPage({
    super.key,
    required this.kind,
    required this.collection,
  });

  final CompletionKind kind;
  final MarketplaceCollection collection;

  @override
  State<MarketplaceCollectionPage> createState() =>
      _MarketplaceCollectionPageState();
}

class _MarketplaceCollectionPageState extends State<MarketplaceCollectionPage> {
  final _search = TextEditingController();
  final _tagged = ValueNotifier(<String>{});
  late final _tags = tagsOf(widget.collection.members);

  @override
  void dispose() {
    _search.dispose();
    _tagged.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.kind;
    final collection = widget.collection;
    return Scaffold(
      appBar: PageBar(
        title: collection.name,
        subtitle: "Marketplace · ${kind.label}",
        actions: [
          if (_tags.isNotEmpty)
            PageAction.icon(
              icon: Icons.filter_list,
              label: "Filter by tag",
              onPressed: () => openTagPicker(context, _tags, _tagged),
            ),
        ],
      ),
      body: Column(
        children: [
          SearchField(
            controller: _search,
            hint: "Search",
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge([_search, _tagged]),
              builder: (context, _) => CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: CollectionCards(
                      kind: kind,
                      collections: [collection],
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SectionHeader(
                      countOf(kind, collection.members.length),
                    ),
                  ),
                  ..._entries(
                    kind,
                    entriesMatching(
                      collection.members,
                      _search.text,
                      _tagged.value,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
