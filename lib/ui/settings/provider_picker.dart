import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/llm_provider.dart";

import "../../app/settings/provider_filter.dart";
import "../../data/builtin/llm/providers/presets.dart";
import "../../providers.dart";
import "../widgets/catalog.dart" show InfoTag, InfoTone;
import "package:entoli_core/view/widgets/empty_pane.dart";

import "../widgets/chip_row.dart";
import "../widgets/provider_mark.dart";
import "../widgets/toggle_chip.dart";

/// Ask which provider to add, on a page of its own: every offer as a card,
/// narrowed by the tags and companies picked above them. A free tier paid
/// for in privacy is accepted here, in a dialog, before the key is asked
/// for. A card picked is handed to [connect] over the page, a null preset
/// being Custom, and the page stays until it says the provider was added:
/// backing out of the sign-in is back to the choice, not past it. One already
/// configured is offered again, for a second account.
Future<void> showProviderPicker(
  BuildContext context, {
  required Connect connect,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => ProviderPickerPage(connect: connect),
  ),
);

/// Sign [preset] in, over [context]; whether it was added.
typedef Connect =
    Future<bool> Function(BuildContext context, LlmProvider? preset);

class ProviderPickerPage extends ConsumerStatefulWidget {
  const ProviderPickerPage({super.key, required this.connect});

  final Connect connect;

  @override
  ConsumerState<ProviderPickerPage> createState() => _ProviderPickerPageState();
}

class _ProviderPickerPageState extends ConsumerState<ProviderPickerPage> {
  final _offers = providerOffers();
  late final _makers = makersOf(_offers);
  var _filter = const ProviderFilter();

  Future<void> _choose(LlmProvider? offer) async {
    final terms = offer?.terms;
    final warning = terms?.freeTier;
    if (warning != null &&
        !await _acceptFreeTier(context, ref, offer!, terms!, warning)) {
      return;
    }
    if (!mounted || !await widget.connect(context, offer)) return;
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _offers.where(_filter.admits).toList();
    // A page route has no barrier to take Escape, as the dialog it was did.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.maybePop(context),
      },
      child: Focus(autofocus: true, child: _page(context, shown)),
    );
  }

  Widget _page(BuildContext context, List<LlmProvider> shown) {
    return Scaffold(
      appBar: AppBar(title: const Text("Add provider")),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _FilterRow(
            items: ProviderTag.values,
            leading: (tag) => Icon(tag.icon, size: 18),
            label: (tag) => tag.label,
            selected: _filter.tags.contains,
            onToggle: (tag) => setState(() => _filter = _filter.toggleTag(tag)),
          ),
          const SizedBox(height: 8),
          _FilterRow(
            items: _makers,
            leading: (maker) =>
                ProviderMark(maker, radius: ToggleChip.markSize / 2),
            label: (maker) => maker,
            selected: _filter.makers.contains,
            onToggle: (maker) =>
                setState(() => _filter = _filter.toggleMaker(maker)),
          ),
          const SizedBox(height: 16),
          if (shown.isEmpty)
            const EmptyPane(
              icon: Icons.filter_alt_off_outlined,
              title: "No provider is all of these.",
              detail: "Untick a filter to see more.",
            ),
          _CardGrid(
            children: [
              for (final offer in shown)
                ProviderCard(offer, onTap: () => _choose(offer)),
              // An endpoint typed in has no tags, so any filter leaves it out.
              if (_filter.isEmpty)
                _OfferCard(
                  leading: const CircleAvatar(child: Icon(Icons.link)),
                  title: "Custom endpoint",
                  onTap: () => _choose(null),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A row of things to filter by, each ticked on and off.
class _FilterRow<T extends Object> extends StatelessWidget {
  const _FilterRow({
    required this.items,
    required this.leading,
    required this.label,
    required this.selected,
    required this.onToggle,
  });

  final List<T> items;
  final Widget Function(T) leading;
  final String Function(T) label;
  final bool Function(T) selected;
  final void Function(T) onToggle;

  @override
  Widget build(BuildContext context) => ChipRow(
    settled: true,
    entries: [
      for (final item in items)
        ChipRowEntry(
          key: ValueKey(item),
          child: ToggleChip(
            leading: leading(item),
            label: Text(label(item)),
            selected: selected(item),
            onSelected: (_) => onToggle(item),
          ),
        ),
    ],
  );
}

/// Cards as many abreast as fit at a readable width, one on a phone.
class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.children});

  static const _minWidth = 320.0;
  static const _gap = 12.0;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = ((constraints.maxWidth + _gap) / (_minWidth + _gap))
          .floor()
          .clamp(1, 4);
      final width = (constraints.maxWidth - _gap * (columns - 1)) / columns;
      return Wrap(
        spacing: _gap,
        runSpacing: _gap,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}

/// One offer on the page: its company's mark, its name, and the tags it is
/// filtered by.
class ProviderCard extends StatelessWidget {
  const ProviderCard(this.offer, {super.key, required this.onTap});

  final LlmProvider offer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _OfferCard(
    leading: ProviderMark(offer.maker),
    title: offer.displayName,
    tags: [
      for (final tag in ProviderTag.values)
        if (offer.tags.contains(tag))
          InfoTag(tag.icon, tag.label, tone: tag.tone),
      ?_caveat(offer.terms?.prompts),
      if (offer case final CliProvider cli)
        InfoTag(Icons.account_circle_outlined, cli.account),
      if (offer.imageModel != null)
        const InfoTag(Icons.image_outlined, "Images"),
    ],
    onTap: onTap,
  );

  /// What the tags leave unsaid about the prompts, where it is a warning.
  static InfoTag? _caveat(PromptUse? use) => switch (use) {
    PromptUse.trainedWhenFree => const InfoTag(
      Icons.visibility_outlined,
      "Free tier trains on prompts",
      tone: InfoTone.warn,
    ),
    PromptUse.unstated => const InfoTag(
      Icons.help_outline,
      "Free tier terms unclear",
      tone: InfoTone.warn,
    ),
    PromptUse.dependsOnRoute => const InfoTag(
      Icons.alt_route,
      "Training depends on the model",
    ),
    PromptUse.local || PromptUse.notTrained || null => null,
  };
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({
    required this.leading,
    required this.title,
    required this.onTap,
    this.tags = const [],
  });

  final Widget leading;
  final String title;
  final List<Widget> tags;
  final VoidCallback onTap;

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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  leading,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleMedium),
                  ),
                ],
              ),
              if (tags.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 6, runSpacing: 4, children: tags),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// How a tag is drawn, on a filter chip and on a card.
extension on ProviderTag {
  IconData get icon => switch (this) {
    ProviderTag.private => Icons.lock_outline,
    ProviderTag.privacyControls => Icons.tune,
    ProviderTag.paid => Icons.payments_outlined,
    ProviderTag.free => Icons.redeem_outlined,
  };

  InfoTone get tone =>
      this == ProviderTag.private ? InfoTone.good : InfoTone.plain;
}

Future<bool> _acceptFreeTier(
  BuildContext context,
  WidgetRef ref,
  LlmProvider preset,
  PresetTerms terms,
  String warning,
) async {
  final colors = Theme.of(context).colorScheme;
  final policy = terms.policy;
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: Icon(Icons.privacy_tip_outlined, color: colors.error),
      title: Text("${preset.displayName}'s free tier is not private"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(warning),
          if (policy != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text("Read their terms"),
              onPressed: () =>
                  ref.read(linkOpenerProvider).open(context, Uri.parse(policy)),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text("Cancel"),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          style: TextButton.styleFrom(foregroundColor: colors.error),
          child: const Text("I understand, add it"),
        ),
      ],
    ),
  );
  return answer ?? false;
}
