import "package:flutter/material.dart";

import "floating_position.dart";

/// How long an entry's grow or shrink runs, and how long a leaving entry's
/// slot is held for the shrink before it goes — the hold and the tween are
/// the same motion, so the two must not drift apart.
const _motion = Duration(milliseconds: 180);

/// One entry of a [ChipRow]: what it is, named by a stable key, and the chip
/// to draw for it. The key is how the row tells staying from arriving and
/// leaving across builds — it should be the thing's identity, not its
/// position.
class ChipRowEntry {
  const ChipRowEntry({required this.key, required this.child});

  final Key key;
  final Widget child;
}

/// A centred row of chips that animates a change of set per entry rather
/// than swapping the row whole. What stays keeps its slot while its
/// neighbours' slots open and shut around it; what arrives grows out of
/// nothing; what leaves shrinks away before going; and every entry glides
/// to wherever the row next puts it — including across lines, the push a
/// longer neighbour gives. This is the empty-chat screen's motion for its
/// project badges and its `/skill`/`@agent` chips, and anything else that
/// wants the same.
///
/// The row animates on its first build too: a row is grown into, not shown
/// settled, which is what keeps one rule for every change. [settled] is the
/// caller's say-so not to: the entries a screen is built with while it is
/// appearing are already there, and everything from the first change on
/// animates.
class ChipRow extends StatefulWidget {
  const ChipRow({super.key, required this.entries, this.settled = false});

  final List<ChipRowEntry> entries;

  /// Whether the entries the row is first built with are already there.
  /// Snapshot at the row's own first build: kept entries stay settled
  /// whatever a later rebuild says, and entries arriving after animate as
  /// always.
  final bool settled;

  @override
  State<ChipRow> createState() => _ChipRowState();
}

/// One chip on screen, including one already out of the set whose shrink is
/// still running. A class rather than a record for identity: a pending
/// removal is matched against the very instance it was scheduled for, so a
/// revival that builds a fresh instance cannot be removed by it.
class _Shown {
  _Shown(this.key, this.child, {this.settled = false}) : exiting = false;

  final Key key;
  final Widget child;

  /// Whether this entry was on the row the row was first built with —
  /// snapshot there, so a kept entry's tween stays degenerate without
  /// relying on what a retarget would do to a flipped flag.
  bool settled;
  bool exiting;
}

class _ChipRowState extends State<ChipRow> {
  late List<_Shown> shown;

  @override
  void initState() {
    super.initState();
    shown = [
      for (final entry in widget.entries)
        _Shown(entry.key, entry.child, settled: widget.settled),
    ];
  }

  @override
  void didUpdateWidget(ChipRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = {for (final entry in widget.entries) entry.key: entry};
    final kept = <_Shown>[];
    for (final entry in shown) {
      // Persists, or comes back mid-exit: a fresh instance either way, so a
      // removal scheduled for the old one passes it by and the entry's own
      // tween retargets home.
      final match = next.remove(entry.key);
      if (match != null) {
        kept.add(_Shown(entry.key, match.child, settled: entry.settled));
      } else {
        if (!entry.exiting) {
          entry.exiting = true;
          _scheduleGone(entry);
        }
        kept.add(entry);
      }
    }
    // Whatever `next` still holds is arriving: every key the row already
    // showed has been consumed out of it.
    shown = kept..addAll(next.values.map((e) => _Shown(e.key, e.child)));
  }

  void _scheduleGone(_Shown entry) {
    Future.delayed(_motion, () {
      if (!mounted) {
        return;
      }
      setState(() {
        shown.removeWhere((held) => identical(held, entry));
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: _motion,
      curve: Curves.easeOut,
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final entry in shown)
            FloatingPosition(
              // Under the entry's key: it is how the wrap's children match up
              // across builds, and it is the caller's identity for the chip.
              key: entry.key,
            child: _EnterExit(
              exiting: entry.exiting,
              settled: entry.settled,
              child: entry.child,
            ),
            ),
        ],
      ),
    );
  }
}

/// An entry slot that grows out of nothing and shrinks back into it, the
/// child fading and scaling inside so the whole reads as one motion. The
/// slot's width is the tween, so the row re-flows every frame and the
/// neighbours glide rather than jump; the scale is the tween too, so painted
/// size follows slot size and what appears from nothing is the child itself.
class _EnterExit extends StatelessWidget {
  const _EnterExit({required this.child, this.exiting = false, this.settled = false});

  final Widget child;
  final bool exiting;

  /// The `begin` a first build carries: 1.0 rather than 0.0. The tween is
  /// then degenerate, and `TweenAnimationBuilder` runs nothing on it —
  /// whatever was on the row when it was first built is already there. The
  /// flag rides the entry rather than the widget, so it never changes for a
  /// living entry and the flip question does not arise.
  final bool settled;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder(
      tween: Tween(begin: settled ? 1.0 : 0.0, end: exiting ? 0.0 : 1.0),
      duration: _motion,
      curve: exiting ? Curves.easeIn : Curves.easeOut,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.scale(
          scale: value,
          alignment: Alignment.center,
          child: Align(
            widthFactor: value,
            alignment: Alignment.center,
            child: child,
          ),
        ),
      ),
      child: child,
    );
  }
}