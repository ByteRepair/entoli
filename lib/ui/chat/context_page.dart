import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../domain/prompt_library.dart" show nameOf;
import "../../providers.dart";
import "../widgets/agent_picture.dart";
import "chat_controller.dart";

/// What fills each participant's context window, out of the model's whole,
/// with the auto-compact threshold marked on it.
class ContextPage extends ConsumerWidget {
  const ContextPage({super.key, required this.chatId, this.project});

  final String chatId;

  /// Where a member's picture is looked up.
  final String? project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contexts =
        ref.watch(chatControllerProvider(chatId).select((s) => s.chat))?.contexts ??
            const {};
    final settings = ref.watch(appSettingsProvider);
    final window = ref.watch(agentBackendProvider).contextWindowFor(chatId) ??
        settings.totalContext;
    final threshold = settings.autoCompact ? settings.autoCompactPercent : null;
    // The house first, the members by name.
    final authors = contexts.keys.toList()
      ..sort((a, b) => a == null ? -1 : b == null ? 1 : a.compareTo(b));
    return Scaffold(
      appBar: AppBar(title: const Text("Context")),
      body: contexts.isEmpty
          ? const _Empty()
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
                Text(
                  "The total is the provider's count where it reports one. "
                  "The split is estimated at four characters a token.",
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
    );
  }
}

typedef _Segment = ({String label, Color colour, int Function(ContextUsage) of});

/// Each segment's share of the total, so they sum to the provider's count.
final List<_Segment> _segments = [
  (label: "System prompt", colour: Colors.grey.shade500, of: (u) => u.share(u.system)),
  (label: "Tool definitions", colour: Colors.orange.shade400, of: (u) => u.share(u.tools)),
  (label: "Profile", colour: Colors.green.shade500, of: (u) => u.share(u.profile)),
  (label: "Chat", colour: Colors.blue.shade500, of: (u) => u.share(u.chat)),
];

String _k(int tokens) => tokens < 1000
    ? "$tokens"
    : tokens < 10000
        ? "${(tokens / 1000).toStringAsFixed(1)}k"
        : "${(tokens / 1000).round()}k";

class _ParticipantCard extends StatelessWidget {
  const _ParticipantCard({
    required this.author,
    required this.project,
    required this.usage,
    required this.window,
    required this.threshold,
  });

  /// The reply's author stamp, sigil on; null is the house.
  final String? author;
  final String? project;
  final ContextUsage usage;
  final int window;
  final int? threshold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final used = usage.total;
    final percent = (used * 100 / window).round();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (author == null)
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(Icons.auto_awesome,
                        size: 18, color: theme.colorScheme.onPrimaryContainer),
                  )
                else
                  AgentPicture(name: nameOf(author) ?? author!, project: project),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(author ?? "Entoli Agent",
                      style: theme.textTheme.titleMedium),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text("$percent%", style: theme.textTheme.titleLarge),
                    Text("${_k(used)} / ${_k(window)}",
                        style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Bar(usage: usage, window: window, threshold: threshold),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                for (final s in _segments)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration:
                            BoxDecoration(color: s.colour, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Text(s.label, style: theme.textTheme.bodySmall),
                      const SizedBox(width: 4),
                      Text(_k(s.of(usage)),
                          style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The segments laid end to end over the window, and the threshold's line.
class _Bar extends StatelessWidget {
  const _Bar({required this.usage, required this.window, required this.threshold});

  final ContextUsage usage;
  final int window;
  final int? threshold;

  static const _height = 14.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final used = _segments.fold(0, (sum, s) => sum + s.of(usage));
    // Over the window, the bar is full rather than overflowing.
    final scale = used > window ? used : window;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (threshold != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Align(
                alignment: Alignment(threshold! / 50 - 1, 0),
                child: Text("Auto-compact $threshold%",
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            ),
          SizedBox(
            height: _height + 8,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.centerLeft,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(_height / 2),
                  child: Container(
                    height: _height,
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Row(
                      children: [
                        for (final s in _segments)
                          if (s.of(usage) > 0)
                            Expanded(
                              flex: s.of(usage),
                              child: Tooltip(
                                message: "${s.label}: ${_k(s.of(usage))} tokens",
                                child: Container(color: s.colour),
                              ),
                            ),
                        if (scale > used)
                          Expanded(flex: scale - used, child: const SizedBox()),
                      ],
                    ),
                  ),
                ),
                if (threshold != null)
                  Positioned(
                    left: width * threshold! / 100 - 1,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 2,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurface,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    });
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.data_usage, size: 48, color: muted),
            const SizedBox(height: 12),
            Text("Nothing measured yet", style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              "The context is measured on each request. Send a message to see it.",
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}
