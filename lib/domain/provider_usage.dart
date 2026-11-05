/// What one of a provider's allowances is counted in. A share is a fraction
/// of the allowance with nothing behind it to count: a provider that only says
/// "37% of your week" is a [share] with a max of 1.
enum UsageUnit { share, usd, requests }

/// Something a provider says about what the account has spent or has left:
/// an allowance with a size ([UsageWindow]) or a balance with none
/// ([CreditBalance]).
sealed class ProviderUsage {
  const ProviderUsage(this.label);

  /// What it is, in the provider's own words for its period: "Weekly",
  /// "Monthly credits", "Purchased credits".
  final String label;
}

/// One allowance a provider meters, and how much of it is spent: a five-hour
/// window, a week, a month's dollars. [used] is always what is gone, never
/// what is left — a provider that reports the remainder is converted where it
/// is read, so every bar fills the same way.
class UsageWindow extends ProviderUsage {
  const UsageWindow({
    required String label,
    required this.used,
    required this.max,
    required this.unit,
    this.resetsAt,
  }) : super(label);

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

/// Money the account holds with no allowance behind it — credits bought
/// rather than granted by a plan — so there is what is left and nothing to
/// measure it against.
class CreditBalance extends ProviderUsage {
  const CreditBalance({required String label, required this.usd})
    : super(label);

  /// What is left, in dollars.
  final double usd;

  @override
  bool operator ==(Object other) =>
      other is CreditBalance && other.label == label && other.usd == usd;

  @override
  int get hashCode => Object.hash(label, usd);

  @override
  String toString() => "CreditBalance($label, \$$usd)";
}
