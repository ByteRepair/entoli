import "package:flutter/material.dart";

/// A part of a [SegmentedMeter]: what fills [fraction] of the bar.
class MeterSegment {
  const MeterSegment(this.label, this.amount, this.fraction, this.color);

  final String label;

  /// How much it is, said: "3.2k".
  final String amount;
  final double fraction;
  final Color color;
}

/// A line across a meter at [fraction], [label] over it.
class MeterMark {
  const MeterMark(this.fraction, this.label);

  final double fraction;
  final String label;
}

/// A figure the legend gives beside the segments that is not one of them:
/// what the whole was measured from.
class MeterReading {
  const MeterReading(this.label, this.amount);

  final String label;
  final String amount;
}

/// A meter of segments laid end to end, its mark a line across it named
/// over it, and a legend of what each segment is under it.
class SegmentedMeter extends StatelessWidget {
  const SegmentedMeter({
    super.key,
    required this.segments,
    this.mark,
    this.unit,
    this.readings = const [],
  });

  final List<MeterSegment> segments;
  final MeterMark? mark;

  /// Listed after the segments in the legend, with no colour of their own.
  final List<MeterReading> readings;

  /// What a segment's amount counts, said in its tooltip: "tokens".
  final String? unit;

  static const _height = 14.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final used = segments.fold(0.0, (sum, s) => sum + s.fraction);
    // Over the whole, the bar is full rather than overflowing.
    final scale = used > 1 ? used : 1.0;
    final mark = this.mark;
    // Shrunk with the segments, so it stays where it falls among them.
    final at = (mark?.fraction ?? 0) / scale;
    // Flex wants integers; a thousandth is finer than a pixel here.
    int flex(double f) => (f * 1000).round();
    final drawn = [
      for (final s in segments)
        if (flex(s.fraction) > 0) s,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (mark != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Align(
              alignment: Alignment(at * 2 - 1, 0),
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
                        for (final (i, s) in drawn.indexed)
                          Expanded(
                            flex: flex(s.fraction),
                            child: Tooltip(
                              message:
                                  "${s.label}: ${s.amount}"
                                  "${unit == null ? "" : " $unit"}",
                              // A seam between neighbours, so two segments
                              // of close colours still read as two.
                              child: Container(
                                decoration: BoxDecoration(
                                  color: s.color,
                                  border: i == drawn.length - 1
                                      ? null
                                      : Border(
                                          right: BorderSide(
                                            color: theme.colorScheme.surface,
                                            width: 2,
                                          ),
                                        ),
                                ),
                              ),
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
                  // Haloed in the surface colour, so it shows over any
                  // segment's colour as well as over the track.
                  Positioned(
                    left: constraints.maxWidth * at - 2,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 4,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.onSurface,
                        borderRadius: BorderRadius.circular(2),
                        border: Border.all(
                          color: theme.colorScheme.surface,
                          width: 1,
                        ),
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
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: s.color,
                      borderRadius: BorderRadius.circular(3),
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
        // A line of their own: they measure the whole, and beside the
        // segments they read as more of them.
        if (readings.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              for (final r in readings)
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: "${r.label} "),
                      TextSpan(
                        text: r.amount,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
