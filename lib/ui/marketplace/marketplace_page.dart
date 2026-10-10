import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/log.dart";
import "../../domain/models.dart";
import "../../providers.dart";
import "../widgets/nothing.dart";
import "marketplace.dart";
import "marketplace_entry_preview.dart";
import "marketplace_groups.dart";
import "marketplace_tags.dart";
import "unreachable.dart";

/// One tab's list, fetched on first watch and kept. A refresh re-runs the
/// fetch by invalidating; nothing watches it between visits, so a reopen
/// re-fetches rather than showing what may have changed underneath it —
/// fine at the size a marketplace is, and autoDispose is the way to have it.
///
/// Riverpod's automatic retry is off (`retry: (_, _) => null`): a marketplace
/// fetch fails on the network, and the retry is the user's own Try-again — an
/// automatic one schedules real timers that hold the spinner up through ten
/// rounds of backoff the user cannot see or stop.
final marketplaceEntriesProvider = FutureProvider.autoDispose
    .family<List<MarketplaceEntry>, CompletionKind>(
  (ref, kind) async {
    final client = ref.watch(marketplaceClientProvider);
    try {
      return await fetchMarketplaceEntries(client, kind);
    } catch (e) {
      // Logged once, where it is caught, rather than on every rebuild of the
      // error state the page draws.
      logFailure("marketplace", "could not fetch ${kind.label}", e);
      rethrow;
    }
  },
  retry: (_, _) => null,
);

/// The marketplace: what the site ships, per section, over its tabs. The
/// toolbar's box searches — the name and the description alike, over the
/// entries the fetch already holds — and the filter icon opens the tab's tag
/// picker; both filter the list in the order it is drawn (the site's own
/// entries first, the remote ones under the External heading, each half
/// alphabetical) rather than re-ordering it. Tapping an entry opens its
/// preview page, where Install lives.
class MarketplacePage extends ConsumerStatefulWidget {
  const MarketplacePage({super.key});

  @override
  ConsumerState<MarketplacePage> createState() => _MarketplacePageState();
}

class _MarketplacePageState extends ConsumerState<MarketplacePage> {
  final _search = TextEditingController();

  /// The tabs listen to this rather than the page rebuilding on a keystroke —
  /// the sidebar's reason and its mechanism both.
  final ValueNotifier<String> _query = ValueNotifier("");

  /// The tags ticked per tab, in the page because the tabs outlive the tag
  /// picker page that ticks them; popped for good with it.
  final _tagged = {
    for (final kind in CompletionKind.values) kind: ValueNotifier(<String>{}),
  };

  @override
  void initState() {
    super.initState();
    _search.addListener(() => _query.value = _search.text);
  }

  @override
  void dispose() {
    _search.dispose();
    _query.dispose();
    for (final notifier in _tagged.values) {
      notifier.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Marketplace"),
          actions: [
            Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.filter_list),
                tooltip: "Filter by tag",
                onPressed: () => _openTags(context),
              ),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: "Skills"),
              Tab(text: "Agents"),
            ],
          ),
        ),
        body: Column(
          children: [
            _SearchField(controller: _search, query: _query),
            Expanded(
              child: TabBarView(
                children: [
                  _EntryList(
                    kind: CompletionKind.skill,
                    query: _query,
                    tagged: _tagged[CompletionKind.skill]!,
                  ),
                  _EntryList(
                    kind: CompletionKind.agent,
                    query: _query,
                    tagged: _tagged[CompletionKind.agent]!,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The visible tab's tags, out of the data the tab already holds. The
  /// picker ticks into the page's notifier for the kind, so popping it back
  /// leaves the list filtered.
  void _openTags(BuildContext context) {
    final kind = CompletionKind.values[DefaultTabController.of(context).index];
    final tags = tagsOf(
      ref.read(marketplaceEntriesProvider(kind)).asData?.value ?? const [],
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            MarketplaceTagPickerPage(tags: tags, ticked: _tagged[kind]!),
      ),
    );
  }
}

/// A tab's widgets keep themselves mounted across a tab flip — the other tab
/// is a page away, and without this the autoDispose provider under the one
/// left is disposed on the way out, so every flip re-fetched its index and
/// flashed the spinner over a list the visit already had.
class _EntryList extends ConsumerStatefulWidget {
  const _EntryList({
    required this.kind,
    required this.query,
    required this.tagged,
  });

  final CompletionKind kind;
  final ValueNotifier<String> query;
  final ValueNotifier<Set<String>> tagged;

  @override
  ConsumerState<_EntryList> createState() => _EntryListState();
}

class _EntryListState extends ConsumerState<_EntryList>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ref.watch(marketplaceEntriesProvider(widget.kind)).when(
          data: (entries) => ValueListenableBuilder<String>(
            valueListenable: widget.query,
            builder: (context, query, _) => ValueListenableBuilder<Set<String>>(
              valueListenable: widget.tagged,
              builder: (context, tagged, _) {
                if (entries.isEmpty) {
                  return const Nothing("The marketplace has nothing here yet.");
                }
                final showing = entriesMatching(entries, query, tagged);
                if (showing.isEmpty) {
                  return const Nothing("Nothing matches here.");
                }
                final groups = groupByOrigin(showing);
                return CustomScrollView(
                  slivers: [
                    SliverList.builder(
                      itemCount: groups.local.length,
                      itemBuilder: (context, i) => _EntryTile(
                        entry: groups.local[i],
                        kind: widget.kind,
                      ),
                    ),
                    // The heading between the halves, and only where both
                    // have something — a tab of one half has nothing it
                    // separates.
                    if (groups.remote.isNotEmpty) ...[
                      if (groups.local.isNotEmpty)
                        const SliverToBoxAdapter(
                          child: _Heading(externalHeading),
                        ),
                      SliverList.builder(
                        itemCount: groups.remote.length,
                        itemBuilder: (context, i) => _EntryTile(
                          entry: groups.remote[i],
                          kind: widget.kind,
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Unreachable(
            detail: "$e",
            onRetry: () =>
                ref.invalidate(marketplaceEntriesProvider(widget.kind)),
          ),
        );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.kind});

  final MarketplaceEntry entry;
  final CompletionKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = entry.metaLine;
    return ListTile(
      // Tapping opens the preview page, where Install lives.
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MarketplaceEntryPreviewPage(kind: kind, entry: entry),
        ),
      ),
      title: Text(entry.name, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (meta.isNotEmpty)
            Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      isThreeLine: true,
    );
  }
}

/// The marketplace's search box — the sidebar's rounded one, its copy rather
/// than its import, matching the look it set; extracting waits for a third
/// caller.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.query});

  final TextEditingController controller;

  /// The same text the controller holds, listened to so the clear button
  /// comes and goes without the field itself being rebuilt from above.
  final ValueNotifier<String> query;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: ValueListenableBuilder<String>(
        valueListenable: query,
        builder: (context, text, _) => TextField(
          controller: controller,
          textInputAction: TextInputAction.search,
          style: theme.textTheme.bodyMedium,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest,
            hintText: "Search",
            prefixIcon: const Icon(Icons.search, size: 20),
            prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 36),
            suffixIcon: text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: "Clear search",
                    onPressed: controller.clear,
                  ),
            suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }
}

/// The row the remote half sits under — the sidebar's heading row, its copy.
class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}