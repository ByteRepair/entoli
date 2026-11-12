import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../app/plan.dart" show planProgressLine, planProvider;
import "../../../app/transcript/activity.dart";
import "../../fonts.dart";
import "../plan_page.dart" show openPlan;
import "../widgets/plan_view.dart" show PlanTaskList;
import "glyphs.dart";
import "hand_off.dart";
import "label.dart";

/// A [LabelNode]: the one line, and while a thought is being written its
/// last lines streaming under it.
class LabelNodeView extends StatelessWidget {
  const LabelNodeView(this.node, {super.key, required this.onTap});

  final LabelNode node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = ActivityLabel(
      icon: iconOf(node.shownGlyph),
      text: node.text,
      isError: node.isError,
      iconWidget: node.busy ? labelSpinner(context) : null,
      onTap: onTap,
    );
    final tail = node.tail;
    if (tail == null) return label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        label,
        _ThoughtTail(text: tail, onTap: onTap),
      ],
    );
  }
}

/// The last few lines of a thought being written, faded at the top so it
/// reads as the end of something longer. The detail has the whole of it.
class _ThoughtTail extends StatelessWidget {
  const _ThoughtTail({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  static const _lines = 4;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontStyle: FontStyle.italic,
    );
    final lineHeight = (style?.fontSize ?? 12) * (style?.height ?? 1.4);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          labelPadX + labelIcon + labelGap,
          0,
          labelPadX,
          6,
        ),
        child: ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black],
            stops: [0, 0.45],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: SizedBox(
            height: lineHeight * _lines,
            width: double.infinity,
            // Reversed so the newest line is the one held in view.
            child: SingleChildScrollView(
              reverse: true,
              physics: const NeverScrollableScrollPhysics(),
              child: Text(text, style: style),
            ),
          ),
        ),
      ),
    );
  }
}

/// A [DiffNode]: the lines a small change took out, in red, and put in, in
/// green.
class DiffNodeView extends StatelessWidget {
  const DiffNodeView(this.node, {super.key, required this.onTap});

  final DiffNode node;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final red = theme.colorScheme.error;
    final green = theme.brightness == Brightness.dark
        ? const Color(0xFF3FB950)
        : const Color(0xFF1A7F37);
    TextStyle mono(Color colour) =>
        TextStyle(fontFamily: monoFamily, fontSize: 12.5, color: colour);
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: onTap,
        style: labelStyle(theme.colorScheme.onSurfaceVariant, labelText(theme)),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.description_outlined, size: labelIcon),
                  const SizedBox(width: labelGap),
                  Text(node.title),
                ],
              ),
              const SizedBox(height: 4),
              for (final line in node.removed)
                Text("- $line", style: mono(red)),
              for (final line in node.added)
                Text("+ $line", style: mono(green)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A [PlanNode]: the plan put to the user, every task, each opening to its
/// details. Read off the file rather than the call, so it shows where the
/// work stands now.
class PlanNodeView extends ConsumerWidget {
  const PlanNodeView(this.node, {super.key});

  final PlanNode node;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final chatId = node.run.chatId;
    final plan = ref.watch(planProvider(chatId));
    final sections = plan.value;
    // The whole width of the reply's column, like the reply itself: task
    // details are prose, and a narrow card wrapped them into a ribbon.
    return Card.outlined(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.checklist),
            title: Text(node.title, style: theme.textTheme.titleMedium),
            subtitle: Text(planProgressLine(sections, loading: plan.isLoading)),
            trailing: sections == null
                ? null
                : IconButton(
                    tooltip: "Open the plan",
                    icon: const Icon(Icons.open_in_full),
                    onPressed: () => openPlan(context, chatId),
                  ),
          ),
          if (sections != null) PlanTaskList(sections: sections),
        ],
      ),
    );
  }
}

/// An [OutputNode]: a card the user taps to open what the turn made.
class OutputNodeView extends StatelessWidget {
  const OutputNodeView(this.node, {super.key});

  final OutputNode node;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (kind, icon, action, background, foreground) = switch (node.kind) {
      OutputKind.artifact => (
        "Artifact",
        Icons.insert_chart_outlined,
        Icons.open_in_new,
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      OutputKind.skill => (
        "Skill",
        Icons.extension,
        Icons.install_desktop,
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Material(
          color: background,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => node.open(ContextHandOff(context)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: foreground.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon, size: 20, color: foreground),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          kind,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: foreground.withValues(alpha: 0.75),
                            letterSpacing: 0.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          node.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: foreground,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    action,
                    size: 18,
                    color: foreground.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
