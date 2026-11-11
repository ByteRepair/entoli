import "package:flutter/widgets.dart";

/// Whether the motion below that never ends and says nothing may run — a
/// live Bot Avatar, the thinking slider's field. On where nothing says, and
/// off where the platform asks for reduced motion. The test harness turns it
/// off: a page holding endless motion never comes to rest, so nothing can
/// wait for it to, and the motion is not what any test of the page is about.
/// A widget's own test pumps it directly to see it move.
class DecorativeMotion extends InheritedWidget {
  const DecorativeMotion({
    super.key,
    required this.enabled,
    required super.child,
  });

  final bool enabled;

  static bool of(BuildContext context) =>
      !(MediaQuery.maybeDisableAnimationsOf(context) ?? false) &&
      (context
              .dependOnInheritedWidgetOfExactType<DecorativeMotion>()
              ?.enabled ??
          true);

  @override
  bool updateShouldNotify(DecorativeMotion old) => old.enabled != enabled;
}
