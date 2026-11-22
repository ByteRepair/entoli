import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/marketplace/face.dart";
import "../../app/marketplace/groups.dart";
import "../../app/marketplace/marketplace.dart";
import "../../domain/models.dart";
import "../../providers.dart";
import "../bot_avatar/bot_avatar_view.dart";

/// What an entry or a collection of another repository's says it is.
const externalBadge = "External";

/// How many [kind] there are, as a heading or a card says it.
String countOf(CompletionKind kind, int n) => switch (kind) {
  CompletionKind.skill => n == 1 ? "1 skill" : "$n skills",
  CompletionKind.agent => n == 1 ? "1 agent" : "$n agents",
};

/// [text] cut at a word to about two lines of a row.
String _short(String text, [int max = 140]) {
  if (text.length <= max) return text;
  final cut = text.lastIndexOf(" ", max);
  return "${text.substring(0, cut > max ~/ 2 ? cut : max).trimRight()}…";
}

/// A row's face: a still Bot Avatar picked from [slug], or the kind's icon
/// until the presets load. Stills, since a list of hundreds of live faces is
/// a ticker a row.
class MarketplaceFace extends ConsumerWidget {
  const MarketplaceFace({
    super.key,
    required this.slug,
    required this.icon,
    this.size = 40,
  });

  final String slug;
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presets = ref.watch(botAvatarPresetsProvider).value ?? const [];
    if (marketplaceFace(slug, presets) case final spec?) {
      return BotAvatarView(spec: spec, size: size, animate: false);
    }
    return SizedBox.square(
      dimension: size,
      child: Icon(
        icon,
        size: size * 0.6,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

IconData kindIcon(CompletionKind kind) => switch (kind) {
  CompletionKind.skill => Icons.extension,
  CompletionKind.agent => Icons.person_outline,
};

/// Who made it, in the accent.
class MarketplaceByline extends StatelessWidget {
  const MarketplaceByline(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.primary,
      ),
    );
  }
}

/// A pill in the corner: [externalBadge].
class MarketplaceBadge extends StatelessWidget {
  const MarketplaceBadge(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: tone),
      ),
    );
  }
}

/// One entry, for scanning: who made it and the version, the description
/// cut short.
class EntryTile extends StatelessWidget {
  const EntryTile({
    super.key,
    required this.entry,
    required this.kind,
    required this.onTap,
  });

  final MarketplaceEntry entry;
  final CompletionKind kind;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byline = [
      ?entry.byline,
      if (entry.version case final version?) "v$version",
    ].join(" · ");
    return ListTile(
      leading: MarketplaceFace(slug: entry.slug, icon: kindIcon(kind)),
      title: Text(entry.name, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (byline.isNotEmpty) MarketplaceByline(byline),
          if (entry.description.isNotEmpty)
            Text(
              _short(entry.description),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      trailing: entry.external ? const MarketplaceBadge(externalBadge) : null,
      onTap: onTap,
    );
  }
}

/// Collections as cards, up to three across; [onOpen] null is a card that
/// heads its own page.
class CollectionCards extends StatelessWidget {
  const CollectionCards({
    super.key,
    required this.kind,
    required this.collections,
    this.onOpen,
  });

  final CompletionKind kind;
  final List<MarketplaceCollection> collections;
  final void Function(MarketplaceCollection collection)? onOpen;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const gap = 12.0;
      final inner = box.maxWidth - 32;
      final across = (inner / 280).floor().clamp(
        1,
        collections.length.clamp(1, 3),
      );
      final width = (inner - gap * (across - 1)) / across;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final collection in collections)
              SizedBox(
                width: width,
                child: MarketplaceCard(
                  slug: collection.slug,
                  icon: Icons.folder_outlined,
                  title: collection.name,
                  byline: countOf(kind, collection.members.length),
                  words: collection.summary,
                  external: collection.external,
                  onTap: switch (onOpen) {
                    final open? => () => open(collection),
                    null => null,
                  },
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// One card: a face, a title, who made it or how much it holds, a few lines
/// of words and the External pill.
class MarketplaceCard extends StatelessWidget {
  const MarketplaceCard({
    super.key,
    required this.slug,
    required this.icon,
    required this.title,
    this.face,
    this.byline,
    this.words,
    this.external = false,
    this.onTap,
  });

  final String slug;
  final IconData icon;
  final String title;

  /// Drawn in place of the still picked from [slug]: an agent's own picture.
  final Widget? face;
  final String? byline;
  final String? words;
  final bool external;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              face ?? MarketplaceFace(slug: slug, icon: icon, size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    if (byline case final byline?)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: MarketplaceByline(byline),
                      ),
                    if (words case final words? when words.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          words,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (external)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: MarketplaceBadge(externalBadge),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
