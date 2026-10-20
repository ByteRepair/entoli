import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/llm_provider.dart";
import "../../providers.dart";

/// Ask which provider to add, saying beside each preset what it does with the
/// prompts it is sent. A free tier paid for in privacy is accepted here, in a
/// second dialog, before the key is asked for. Null if dismissed; a null
/// [preset] is Custom.
Future<({LlmProviderConfig? preset})?> pickProviderPreset(
  BuildContext context, {
  required Set<String> configured,
}) => showDialog<({LlmProviderConfig? preset})>(
  context: context,
  builder: (context) => _PresetPicker(configured: configured),
);

class _PresetPicker extends ConsumerWidget {
  const _PresetPicker({required this.configured});

  final Set<String> configured;

  Future<void> _choose(
    BuildContext context,
    WidgetRef ref,
    LlmProviderConfig preset,
    PresetTerms? terms,
  ) async {
    final warning = terms?.freeTier;
    if (warning != null &&
        !await _acceptFreeTier(context, ref, preset, terms!, warning)) {
      return;
    }
    if (context.mounted) Navigator.pop(context, (preset: preset));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offered = [
      for (final p in llmProviderPresets)
        if (!configured.contains(p.id))
          (preset: p, terms: PresetTerms.of(p.id)),
    ];
    bool free(PresetTerms? t) => t?.freeTier != null;
    bool local(PresetTerms? t) => t?.prompts == PromptUse.local;
    final groups = [
      ("Paid", offered.where((o) => !free(o.terms) && !local(o.terms))),
      ("Free, at a cost to privacy", offered.where((o) => free(o.terms))),
      ("On this machine", offered.where((o) => local(o.terms))),
    ];

    return AlertDialog(
      title: const Text("Add provider"),
      // The default 40px a side leaves a phone too little room for the tags.
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (heading, entries) in groups)
                if (entries.isNotEmpty) ...[
                  _GroupHeading(heading),
                  for (final o in entries)
                    _PresetTile(
                      preset: o.preset,
                      terms: o.terms,
                      onTap: () => _choose(context, ref, o.preset, o.terms),
                    ),
                ],
              const Divider(),
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text("Custom…"),
                subtitle: const Text(
                  "Any OpenAI- or Anthropic-compatible "
                  "endpoint, by URL.",
                ),
                onTap: () => Navigator.pop(context, (preset: null)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Cancel"),
        ),
      ],
    );
  }
}

Future<bool> _acceptFreeTier(
  BuildContext context,
  WidgetRef ref,
  LlmProviderConfig preset,
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

class _GroupHeading extends StatelessWidget {
  const _GroupHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.terms,
    required this.onTap,
  });

  final LlmProviderConfig preset;
  final PresetTerms? terms;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final terms = this.terms;
    final colors = Theme.of(context).colorScheme;
    final local = terms?.prompts == PromptUse.local;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: colors.secondaryContainer,
        foregroundColor: colors.onSecondaryContainer,
        child: Icon(local ? Icons.computer : Icons.cloud_outlined),
      ),
      title: Text(preset.displayName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (terms != null) Text(terms.blurb),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (terms?.freeTier != null)
                _Tag(Icons.warning_amber_rounded, "Free", tone: _Tone.warn),
              if (terms != null) _promptsTag(terms.prompts),
              if (LlmProviderConfig.imageDefaultOf(preset) != null)
                const _Tag(Icons.image_outlined, "Images"),
            ],
          ),
        ],
      ),
      isThreeLine: true,
      onTap: onTap,
    );
  }

  static _Tag _promptsTag(PromptUse use) => switch (use) {
    PromptUse.local => const _Tag(
      Icons.lock_outline,
      "Stays on your machine",
      tone: _Tone.good,
    ),
    PromptUse.notTrained => const _Tag(
      Icons.shield_outlined,
      "Doesn't train on prompts",
      tone: _Tone.good,
    ),
    PromptUse.dependsOnRoute => const _Tag(
      Icons.alt_route,
      "Training depends on the model",
    ),
    PromptUse.trainedWhenFree => const _Tag(
      Icons.visibility_outlined,
      "Free tier trains on prompts",
      tone: _Tone.warn,
    ),
    PromptUse.unstated => const _Tag(
      Icons.help_outline,
      "Free tier terms unclear",
      tone: _Tone.warn,
    ),
  };
}

enum _Tone { neutral, good, warn }

class _Tag extends StatelessWidget {
  const _Tag(this.icon, this.label, {this.tone = _Tone.neutral});

  final IconData icon;
  final String label;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (bg, fg) = switch (tone) {
      _Tone.neutral => (
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      ),
      _Tone.good => (colors.primaryContainer, colors.onPrimaryContainer),
      _Tone.warn => (colors.errorContainer, colors.onErrorContainer),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        // Not a full pill: on a narrow screen the label wraps to two lines.
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg),
            ),
          ),
        ],
      ),
    );
  }
}
