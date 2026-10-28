import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/room/room_state.dart" show ChatViewState;
import "../tool_ui/command_ui.dart" show JobsRunning;
import "../tool_ui/task_ui.dart" show SubAgentsRunning;
import "activity_label.dart" show plural;
import "browser_strip.dart" show BrowserRunning;
import "running_pill.dart";

/// Every kind of thing a chat can have running, in the order the row shows
/// them: the browser's tab, standing alone, ahead of the groups.
const runningSources = <RunningSource>[
  BrowserRunning(),
  JobsRunning(),
  SubAgentsRunning(),
];

/// What the chat has running beside the reply, as one row of pills that
/// scrolls sideways: what each of [runningSources] has, those of a kind
/// gathered into a group that opens to a pill apiece. Not turn-scoped: a
/// browser tab and a job outlive the turn that started them.
class RunningStrip extends ConsumerStatefulWidget {
  const RunningStrip({super.key, required this.view});

  final ChatViewState view;

  @override
  ConsumerState<RunningStrip> createState() => _RunningStripState();
}

class _RunningStripState extends ConsumerState<RunningStrip> {
  final _scroll = ScrollController();

  /// The groups open, by kind. The strip's own, not the chat's.
  final _open = <String>{};

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// A mouse wheel turned over the row scrolls it sideways, with no Shift:
  /// the row is the one thing under the pointer that scrolls.
  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final delta = (event as PointerScrollEvent).scrollDelta;
      final position = _scroll.position;
      position.jumpTo((position.pixels + delta.dy + delta.dx)
          .clamp(position.minScrollExtent, position.maxScrollExtent));
    });
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    final chatId = view.chat?.state.id;
    if (chatId == null) return const SizedBox.shrink();
    final alone = <RunningThing>[];
    final groups = <String, List<RunningThing>>{};
    for (final source in runningSources) {
      for (final thing in source.things(ref, view, chatId)) {
        final group = thing.group;
        group == null ? alone.add(thing) : (groups[group] ??= []).add(thing);
      }
    }
    Widget pill(RunningThing thing) => Builder(
          builder: (context) => RunningPill(
            label: thing.label,
            tooltip: thing.tooltip,
            icon: thing.icon,
            mono: thing.mono,
            onPressed: () => thing.open(context),
          ),
        );
    return Listener(
      onPointerSignal: _wheel,
      child: SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            for (final thing in alone)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 4, 8, 4),
                child: pill(thing),
              ),
            for (final MapEntry(key: kind, value: things) in groups.entries)
              _Group(
                label: "${plural(things.length, kind)} running",
                open: _open.contains(kind),
                onToggle: () => setState(
                    () => _open.contains(kind) ? _open.remove(kind) : _open.add(kind)),
                children: [for (final thing in things) pill(thing)],
              ),
          ],
        ),
      ),
    );
  }
}

/// "3 sub-agents running", which a tap opens to a pill per sub-agent and
/// closes again. Open, the pills sit inside it, on its own surface.
class _Group extends StatelessWidget {
  const _Group({
    required this.label,
    required this.open,
    required this.onToggle,
    required this.children,
  });

  final String label;
  final bool open;
  final VoidCallback onToggle;
  final List<Widget> children;

  static const _duration = Duration(milliseconds: 260);
  static const _curve = Curves.easeOutCubic;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final header = InkWell(
      customBorder: const StadiumBorder(),
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            runningSpinner(scheme.primary),
            const SizedBox(width: 8),
            Text(label,
                style: theme.textTheme.labelMedium
                    ?.copyWith(fontWeight: FontWeight.w500)),
            // Points the way the pills open, and back once they have.
            AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: _duration,
              curve: _curve,
              child: Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 8, 4),
      child: Material(
        color: scheme.surfaceContainerLowest,
        shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant)),
        clipBehavior: Clip.antiAlias,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            header,
            // Revealed from the left as the group widens, fading in at their
            // own size, and the same way back.
            TweenAnimationBuilder<double>(
              tween: Tween(end: open ? 1 : 0),
              duration: _duration,
              curve: _curve,
              builder: (context, t, pills) => t == 0
                  ? const SizedBox.shrink()
                  : ClipRect(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        widthFactor: t,
                        child: Opacity(opacity: t, child: pills),
                      ),
                    ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final child in children)
                    Padding(padding: const EdgeInsets.only(right: 4), child: child),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
