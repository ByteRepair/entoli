import "package:flutter/material.dart";

import "../../app/settings/controller.dart";
import "../widgets/prompt_field.dart";

/// A [PromptController] as a [PromptField]: the text as it will be read, a
/// tap opening the core's editor page.
class PromptPreview extends StatelessWidget {
  const PromptPreview(this.c, {super.key});

  final PromptController c;

  @override
  Widget build(BuildContext context) => PromptField(
    label: c.title,
    value: c.text,
    hint: c.placeholder,
    editable: c.enabled,
    onChanged: (_) {},
    onEdit: c.open,
  );
}

Color _hue(MeterHue hue) => switch (hue) {
  MeterHue.grey => Colors.grey.shade500,
  MeterHue.orange => Colors.orange.shade400,
  MeterHue.green => Colors.green.shade500,
  MeterHue.purple => Colors.purple.shade300,
  MeterHue.blue => Colors.blue.shade500,
};

/// A meter of segments laid end to end, its mark a line across it named
/// over it, and a legend of what each segment is under it.
class SegmentedMeter extends StatelessWidget {
  const SegmentedMeter(this.meter, {super.key});

  final ItemMeter meter;

  static const _height = 14.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final segments = meter.segments;
    final used = segments.fold(0.0, (sum, s) => sum + s.fraction);
    // Over the whole, the bar is full rather than overflowing.
    final scale = used > 1 ? used : 1.0;
    final mark = meter.mark;
    // Flex wants integers; a thousandth is finer than a pixel here.
    int flex(double f) => (f * 1000).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (mark != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Align(
              alignment: Alignment(mark.fraction * 2 - 1, 0),
              child: Text(
                mark.label,
                style: theme.textTheme.labelSmall?.copyWith(color: muted),
              ),
            ),
          ),
        LayoutBuilder(
          builder: (context, constraints) => SizedBox(
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
                        for (final s in segments)
                          if (flex(s.fraction) > 0)
                            Expanded(
                              flex: flex(s.fraction),
                              child: Tooltip(
                                message: "${s.label}: ${s.amount} tokens",
                                child: Container(color: _hue(s.hue)),
                              ),
                            ),
                        if (flex(scale - used) > 0)
                          Expanded(
                            flex: flex(scale - used),
                            child: const SizedBox(),
                          ),
                      ],
                    ),
                  ),
                ),
                if (mark != null)
                  Positioned(
                    left: constraints.maxWidth * mark.fraction - 1,
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
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            for (final s in segments)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _hue(s.hue),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(s.label, style: theme.textTheme.bodySmall),
                  const SizedBox(width: 4),
                  Text(
                    s.amount,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}
