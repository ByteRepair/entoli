import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/log.dart";
import "../../domain/models.dart";
import "../../providers.dart";
import "../widgets/nothing.dart";
import "marketplace.dart";
import "marketplace_entry_preview.dart";
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

/// The marketplace: what the site ships, per section, over its tabs. Tapping
/// an entry opens its preview page, where Install lives.
class MarketplacePage extends StatelessWidget {
  const MarketplacePage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Marketplace"),
          bottom: const TabBar(
            tabs: [
              Tab(text: "Skills"),
              Tab(text: "Agents"),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _EntryList(kind: CompletionKind.skill),
            _EntryList(kind: CompletionKind.agent),
          ],
        ),
      ),
    );
  }
}

/// A tab's widgets keep themselves mounted across a tab flip — the other tab
/// is a page away, and without this the autoDispose provider under the one
/// left is disposed on the way out, so every flip re-fetched its index and
/// flashed the spinner over a list the visit already had.
class _EntryList extends ConsumerStatefulWidget {
  const _EntryList({required this.kind});

  final CompletionKind kind;

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
          data: (entries) => entries.isEmpty
              ? const Nothing("The marketplace has nothing here yet.")
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, i) => _EntryTile(
                    entry: entries[i],
                    kind: widget.kind,
                  ),
                ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Unreachable(
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