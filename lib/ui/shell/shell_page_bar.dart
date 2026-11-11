import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/widgets.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../widgets/page_bar.dart";
import "glyphs.dart";
import "shell_outbox.dart";
import "shell_answers.dart";

/// [bar] as the window's title bar: this frontend's `pageBarDrawProvider`.
/// Draws nothing of its own but what goes under the window's bar, which the
/// shell reports as padding, and the page's [PageBar.bottom].
Widget drawShellPageBar(BuildContext context, PageBar bar) {
  final presses = _Presses();
  final dismisses = ModalRoute.of(context)?.impliesAppBarDismissal ?? false;
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ShellPageBar(
        bar: TitleBarSnapshot(
          title: bar.title,
          subtitle: bar.subtitle ?? "",
          leading: switch (bar.leading) {
            PageLeading.close => TitleBarLeading.close,
            PageLeading.back when bar.onBack != null || dismisses =>
              TitleBarLeading.back,
            PageLeading.back => null,
          },
          items: [for (final action in bar.actions) _item(action, presses)],
        ),
        onBack: bar.onBack ?? () => Navigator.of(context).maybePop(),
        actions: presses.runs,
      ),
      SizedBox(height: MediaQuery.paddingOf(context).top),
      ?bar.bottom,
    ],
  );
}

/// One of a page's actions as an item of the window's title bar, what a
/// press runs kept in [presses] under the id the item is sent with.
/// Exhaustive, so a new kind of action is drawn here as well as in Flutter.
TitleBarItem _item(PageAction action, _Presses presses) => switch (action) {
  PageIconAction(:final icon, :final label, :final onPressed) => TitleBarItem(
    id: presses.add(onPressed),
    label: label,
    glyph: glyphOf(icon),
    // An icon the shell has nothing to stand for says what it does instead.
    style: glyphOf(icon) == null
        ? TitleBarItemStyle.text
        : TitleBarItemStyle.icon,
    enabled: onPressed != null,
  ),
  PageConfirmAction(:final label, :final onPressed) => TitleBarItem(
    id: presses.add(onPressed),
    label: label,
    glyph: Glyph.check,
    style: TitleBarItemStyle.confirm,
    enabled: onPressed != null,
  ),
  PageTextAction(:final label, :final onPressed, :final prominent) =>
    TitleBarItem(
      id: presses.add(onPressed),
      label: label,
      style: prominent ? TitleBarItemStyle.prominent : TitleBarItemStyle.text,
      enabled: onPressed != null,
    ),
  PageMenuAction(:final icon, :final label, :final items) => TitleBarItem(
    id: presses.add(null),
    label: label,
    glyph: glyphOf(icon) ?? Glyph.more,
    menu: [
      for (final item in items)
        if (item.enabled)
          TitleBarMenuItem(
            id: presses.add(item.onSelected),
            label: item.label,
            hint: item.hint,
            glyph: glyphOf(item.icon),
            checked: item.checked ?? false,
          ),
    ],
  ),
};

/// What each item of a title bar runs when pressed, by the id it was sent
/// under.
class _Presses {
  final Map<String, VoidCallback> runs = {};
  int _next = 0;

  String add(VoidCallback? run) {
    final id = "${_next++}";
    if (run != null) runs[id] = run;
    return id;
  }
}

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
