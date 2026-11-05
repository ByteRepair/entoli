/// What one of a provider's allowances is counted in. A share is a fraction
/// of the allowance with nothing behind it to count: a provider that only says
/// "37% of your week" is a [share] with a max of 1.
enum UsageUnit { share, usd, requests }

/// One allowance a provider meters, and how much of it is spent: a five-hour
/// window, a week, a month's dollars. [used] is always what is gone, never
/// what is left — a provider that reports the remainder is converted where it
/// is read, so every bar fills the same way.
class UsageWindow {
  const UsageWindow({
    required this.label,
    required this.used,
    required this.max,
    required this.unit,
    this.resetsAt,
  });

  /// What the allowance is, in the provider's own period: "Weekly", "Daily
  /// requests".
  final String label;
  final double used;
  final double max;
  final UsageUnit unit;

  /// When it starts again. Null where the provider does not say.
  final DateTime? resetsAt;

  /// How much of it is spent, from 0 to 1. A max of nothing is an allowance
  /// with no room in it, which is all spent.
  double get fraction => max <= 0 ? 1 : (used / max).clamp(0, 1).toDouble();

  @override
  bool operator ==(Object other) =>
      other is UsageWindow &&
      other.label == label &&
      other.used == used &&
      other.max == max &&
      other.unit == unit &&
      other.resetsAt == resetsAt;

  @override
  int get hashCode => Object.hash(label, used, max, unit, resetsAt);

  @override
  String toString() =>
      "UsageWindow($label, $used/$max ${unit.name}, resets $resetsAt)";
}
