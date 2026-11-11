import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "shell_outbox.dart";
import "shell_answers.dart";

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

  final TitleBarSnapshot bar;
  final VoidCallback onBack;

  /// What a press on each of [bar]'s items runs, by its id, a menu's
  /// choices included.
  final Map<String, VoidCallback> actions;

  @override
  ConsumerState<ShellPageBar> createState() => _ShellPageBarState();
}

class _ShellPageBarState extends ConsumerState<ShellPageBar>
    implements TitleBarIntents {
  /// The pages pushed over the conversation, in the Navigator's order: this
  /// frontend's own navigation, the one in front answering.
  static final List<_ShellPageBarState> _pages = [];

  late final ShellAnswers _answers = ref.read(shellAnswersProvider);
  late final ShellOutbox _outbox = ref.read(shellOutboxProvider);
  Animation<double>? _animation;

  @override
  void initState() {
    super.initState();
    _front();
  }

  void _front() {
    _pages
      ..remove(this)
      ..add(this);
    _answers.pageBar.take(this);
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
        _front();
        _publish();
      case AnimationStatus.dismissed:
        break;
    }
  }

  bool get _onTop => _pages.lastOrNull == this;

  /// Give the title bar to the page beneath, or back to the chat's.
  void _leave() {
    final wasTop = _onTop;
    _pages.remove(this);
    if (!wasTop) return;
    _answers.pageBar.release(this);
    if (_pages.lastOrNull case final under?) {
      _answers.pageBar.take(under);
      under._publish();
    } else {
      _outbox.pageBar(TitleBarSnapshot(present: false, title: ""));
    }
  }

  void _publish() => _outbox.pageBar(widget.bar);

  @override
  void back() => widget.onBack();

  @override
  void press(String id) => widget.actions[id]?.call();

  @override
  Widget build(BuildContext context) {
    // A page beneath rebuilding says nothing: the bar is the one in front's.
    if (_onTop) _publish();
    return const SizedBox.shrink();
  }
}
