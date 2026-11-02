import "package:flutter_riverpod/flutter_riverpod.dart";

/// Whether this platform can draw its chrome with Apple's own, and whether this
/// launch does. [on] is settled at launch and never moves: the native shell
/// owns the window before any page is built, so a change to the setting waits
/// for a restart. See "Liquid Glass" in `lib/ui/AGENTS.md`.
class LiquidGlass {
  const LiquidGlass({this.available = false, this.on = false});

  /// iOS and macOS, whose frameworks draw it; the settings row shows on these
  /// and nowhere else.
  final bool available;

  /// What this launch started with: the window is the native shell's, and
  /// Flutter draws the conversation inside it. See `lib/ui/shell/`.
  final bool on;
}

/// Overridden in `main` with the launch's answer.
final liquidGlassProvider = Provider<LiquidGlass>((ref) => const LiquidGlass());
