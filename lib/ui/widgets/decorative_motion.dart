import "package:flutter/widgets.dart";

/// Whether the motion below that never ends and says nothing may run — a
/// live Bot Avatar, the thinking slider's field. On where nothing says, off
/// where the platform asks for reduced motion; the test harness turns it off
/// (see `test/AGENTS.md`).
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
