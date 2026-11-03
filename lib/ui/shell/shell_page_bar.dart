import "package:flutter/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "shell_outbox.dart";
import "shell_slots.dart";
import "snapshots.dart";

/// A Flutter page's bar, as the window's title bar: `PageBar` under the
/// shell. Draws nothing; sends [bar] while its page is the one in front, and
/// runs what the bar's buttons send back.
///
/// The bars stack as their pages do: each claims the top when it mounts, a
/// page pushed later mounting later, and gives it up as its page starts to
/// leave rather than once it has gone, so the bar beneath is back for the
/// whole of the way back to it.
class ShellPageBar extends ConsumerStatefulWidget {
  const ShellPageBar({
    super.key,
    required this.bar,
    required this.onBack,
    this.actions = const {},
  });

  final PageBarSnapshot bar;
  final VoidCallback onBack;

  /// What a press on each of [bar]'s items runs, by its id, a menu's
  /// choices included.
  final Map<String, VoidCallback> actions;

  @override
  ConsumerState<ShellPageBar> createState() => _ShellPageBarState();
}

class _ShellPageBarState extends ConsumerState<ShellPageBar>
    implements ShellSurface {
  late final ShellSlots _slots = ref.read(shellSlotsProvider);
  late final ShellOutbox _outbox = ref.read(shellOutboxProvider);
  Animation<double>? _animation;

  @override
  void initState() {
    super.initState();
    _slots.claim(ShellConcern.pageBar, this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (animation == _animation) return;
    _animation?.removeStatusListener(_status);
    _animation = animation?..addStatusListener(_status);
  }

  @override
  void dispose() {
    _animation?.removeStatusListener(_status);
    _leave();
    super.dispose();
  }

  /// The page leaving, or a back swipe let go of before it went.
  void _status(AnimationStatus status) {
    switch (status) {
      case AnimationStatus.reverse:
        _leave();
      case AnimationStatus.forward || AnimationStatus.completed:
        if (_onTop) return;
        _slots.claim(ShellConcern.pageBar, this);
        _publish();
      case AnimationStatus.dismissed:
        break;
    }
  }

  bool get _onTop => _slots.top(ShellConcern.pageBar) == this;

  /// Give the title bar to the page beneath, or back to the chat's.
  void _leave() {
    if (!_slots.leave(ShellConcern.pageBar, this)) return;
    final under = _slots.top(ShellConcern.pageBar);
    if (under is _ShellPageBarState) {
      under._publish();
    } else {
      _outbox.post(const PageBarSnapshot.none());
    }
  }

  void _publish() => _outbox.post(widget.bar);

  @override
  Future<Object?> handle(String name, Map<String, Object?> args) async {
    switch (name) {
      case "back":
        widget.onBack();
      case "press":
        widget.actions[args["id"]]?.call();
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // A page beneath rebuilding says nothing: the bar is the one in front's.
    if (_onTop) _publish();
    return const SizedBox.shrink();
  }
}
