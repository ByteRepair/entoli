import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/mirror_controller.dart";
import "../../app/settings/controller.dart"
    show ItemMeter, MeterHue, MeterMark, MeterSegment;
import "../../domain/models.dart";
import "../../domain/prompt_library.dart" show nameOf;
import "../../providers.dart";
import "../settings/rich_rows.dart" show SegmentedMeter;
import "../widgets/agent_picture.dart";
import "../widgets/empty_pane.dart";
import "../widgets/page_bar.dart";
import "../widgets/section_header.dart" show mutedParagraph;

/// Open what fills [chatId]'s context, its participants' faces looked up in
/// [project].
Future<void> openContext(
  BuildContext context, {
  required String chatId,
  String? project,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ContextPage(chatId: chatId, project: project),
  ),
);

/// What fills each participant's context window, out of the model's whole,
/// with the auto-compact threshold marked on it.
class ContextPage extends ConsumerWidget {
  const ContextPage({super.key, required this.chatId, this.project});

  final String chatId;

  /// Where a participant's face is looked up.
  final String? project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contexts =
        ref.watch(chatViewProvider(chatId).select((s) => s.chat))?.contexts ??
        const <String, ContextUsage>{};
    final settings = ref.watch(appSettingsProvider);
    final window =
        ref.watch(contextWindowProvider(chatId)).value ?? settings.totalContext;
    final threshold = settings.autoCompact ? settings.autoCompactPercent : null;
    final authors = contexts.keys.toList()..sort();
    return Scaffold(
      appBar: PageBar(title: "Context"),
      body: contexts.isEmpty
          ? const EmptyPane(
              icon: Icons.data_usage,
              title: "Nothing measured yet",
              detail:
                  "The context is measured on each request. Send a message "
                  "to see it.",
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final author in authors) ...[
                  _ParticipantCard(
                    author: author,
                    project: project,
                    usage: contexts[author]!,
                    window: window,
                    threshold: threshold,
                  ),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 4),
                mutedParagraph(
                  context,
                  "The total is the provider's count where it reports one. "
                  "The split is estimated at four characters a token.",
                  textAlign: TextAlign.center,
                ),
              ],
            ),
    );
  }
}

String _k(int tokens) => tokens < 1000
    ? "$tokens"
    : tokens < 10000
    ? "${(tokens / 1000).toStringAsFixed(1)}k"
    : "${(tokens / 1000).round()}k";

/// [usage] as one bar over [window], each part's share of the provider's
/// count end to end.
ItemMeter _meter(ContextUsage usage, int window, {int? threshold}) {
  MeterSegment segment(String label, int tokens, MeterHue hue) =>
      MeterSegment(label, _k(tokens), tokens / window, hue);
  return ItemMeter(
    "",
    fraction: (usage.total / window).clamp(0, 1),
    mark: threshold == null
        ? null
        : MeterMark(threshold / 100, "Auto-compact $threshold%"),
    segments: [
      segment("System prompt", usage.share(usage.system), MeterHue.grey),
      segment("Tool definitions", usage.share(usage.tools), MeterHue.orange),
      segment("Profile", usage.share(usage.profile), MeterHue.green),
      segment("Instructions", usage.share(usage.instructions), MeterHue.purple),
      segment("Chat", usage.share(usage.chat), MeterHue.blue),
    ],
  );
}

class _ParticipantCard extends StatelessWidget {
  const _ParticipantCard({
    required this.author,
    required this.project,
    required this.usage,
    required this.window,
    required this.threshold,
  });

  /// The reply's author stamp, sigil on.
  final String author;
  final String? project;
  final ContextUsage usage;
  final int window;
  final int? threshold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final used = usage.total;
    final percent = (used * 100 / window).round();
    final name = nameOf(author);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (name != null) ...[
                  AgentPicture(
                    name: name,
                    project: project,
                    animate: true,
                    reactToTap: true,
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(author, style: theme.textTheme.titleMedium),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text("$percent%", style: theme.textTheme.titleLarge),
                    Text(
                      "${_k(used)} / ${_k(window)}",
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            SegmentedMeter(
              _meter(usage, window, threshold: threshold),
              unit: "tokens",
            ),
          ],
        ),
      ),
    );
  }
}
