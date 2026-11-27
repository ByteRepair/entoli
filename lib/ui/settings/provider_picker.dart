import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:entoli_core/model/llm_provider.dart";

import "../../app/settings/provider_filter.dart";
import "../../data/builtin/llm/providers/presets.dart";
import "../../providers.dart";
import "../widgets/catalog.dart" show InfoTag, InfoTone;
import "../widgets/chip_row.dart";
import "../widgets/toggle_chip.dart";

/// Ask which provider to add, on a page of its own: every offer as a card,
/// narrowed by the tags and companies picked above them. A free tier paid
/// for in privacy is accepted here, in a dialog, before the key is asked
/// for. Null if left; a null [preset] is Custom. One already configured is
/// offered again, for a second account.
Future<({LlmProvider? preset})?> pickProviderPreset(BuildContext context) =>
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const ProviderPickerPage(),
      ),
    );

class ProviderPickerPage extends ConsumerStatefulWidget {
  const ProviderPickerPage({super.key});

  @override
  ConsumerState<ProviderPickerPage> createState() => _ProviderPickerPageState();
}

class _ProviderPickerPageState extends ConsumerState<ProviderPickerPage> {
  final _offers = providerOffers();
  late final _makers = makersOf(_offers);
  var _filter = const ProviderFilter();

  Future<void> _choose(LlmProvider offer) async {
    final terms = offer.terms;
    final warning = terms?.freeTier;
    if (warning != null &&
        !await _acceptFreeTier(context, ref, offer, terms!, warning)) {
      return;
    }
    if (mounted) Navigator.pop(context, (preset: offer));
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
          ChipRow(
            settled: true,
            entries: [
              for (final tag in ProviderTag.values)
                ChipRowEntry(
                  key: ValueKey(tag),
                  child: ToggleChip(
                    leading: Icon(tag.icon, size: 18),
                    label: Text(tag.label),
                    selected: _filter.tags.contains(tag),
                    onSelected: (_) =>
                        setState(() => _filter = _filter.toggleTag(tag)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ChipRow(
            settled: true,
            entries: [
              for (final maker in _makers)
                ChipRowEntry(
                  key: ValueKey(maker),
                  child: ToggleChip(
                    leading: MakerMark(maker, radius: 10),
                    label: Text(maker),
                    selected: _filter.makers.contains(maker),
                    onSelected: (_) =>
                        setState(() => _filter = _filter.toggleMaker(maker)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                "No provider is all of these.",
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          _CardGrid(
            children: [
              for (final offer in shown)
                ProviderCard(offer, onTap: () => _choose(offer)),
              // An endpoint typed in has no tags, so any filter leaves it out.
              if (_filter.isEmpty)
                _OfferCard(
                  leading: const _Mark(child: Icon(Icons.link)),
                  title: "Custom",
                  blurb:
                      "Any OpenAI- or Anthropic-compatible endpoint, by URL.",
                  onTap: () => Navigator.pop(context, (preset: null)),
                ),
            ],
          ),
        ],
      ),
    );
  }
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

/// One offer on the page: its company's mark, its name, what it is, and the
/// tags it is filtered by.
class ProviderCard extends StatelessWidget {
  const ProviderCard(this.offer, {super.key, required this.onTap});

  final LlmProvider offer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _OfferCard(
    leading: MakerMark(offer.maker),
    title: offer.displayName,
    blurb: offer.blurb,
    tags: [
      for (final tag in ProviderTag.values)
        if (offer.tags.contains(tag))
          InfoTag(tag.icon, tag.label, tone: tag.tone),
      if (offer.terms?.prompts case final use? when _caveat(use) != null)
        _caveat(use)!,
      if (offer case final CliProvider cli)
        InfoTag(Icons.account_circle_outlined, cli.account),
      if (offer.imageModel != null)
        const InfoTag(Icons.image_outlined, "Images"),
    ],
    onTap: onTap,
  );

  /// What the tags leave unsaid about the prompts, where it is a warning.
  static InfoTag? _caveat(PromptUse use) => switch (use) {
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
    PromptUse.local || PromptUse.notTrained => null,
  };
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({
    required this.leading,
    required this.title,
    required this.onTap,
    this.blurb,
    this.tags = const [],
  });

  final Widget leading;
  final String title;
  final String? blurb;
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
              if (blurb case final blurb?) ...[
                const SizedBox(height: 8),
                Text(blurb, style: theme.textTheme.bodyMedium),
              ],
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

/// A company's mark: its initial in a circle of a hue of its own, so OpenAI
/// and Ollama are told apart by more than the letter. Not its logo, which
/// the companies' trademark terms keep to what they approve.
class MakerMark extends StatelessWidget {
  const MakerMark(this.maker, {super.key, this.radius = 18});

  final String maker;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // A string's hashCode is not stable across runs; its code units are.
    final hue = maker.codeUnits.fold(0, (h, c) => (h * 31 + c) % 360);
    final colour = HSLColor.fromAHSL(
      1,
      hue.toDouble(),
      0.45,
      dark ? 0.3 : 0.85,
    );
    return _Mark(
      radius: radius,
      background: colour.toColor(),
      foreground: colour.withLightness(dark ? 0.9 : 0.2).toColor(),
      child: Text(
        maker.characters.first.toUpperCase(),
        style: TextStyle(fontSize: radius, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _Mark extends StatelessWidget {
  const _Mark({
    required this.child,
    this.radius = 18,
    this.background,
    this.foreground,
  });

  final Widget child;
  final double radius;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: radius,
      backgroundColor: background ?? colors.secondaryContainer,
      foregroundColor: foreground ?? colors.onSecondaryContainer,
      child: child,
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
