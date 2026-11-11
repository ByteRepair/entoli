import "../core/formatting.dart" show formatUntil;
import "../domain/provider_usage.dart";

/// [usage] as one line, at [now]: what is spent of what and when it starts
/// again where the provider says, or what is left of a balance.
String describeUsage(ProviderUsage usage, DateTime now) => switch (usage) {
  CreditBalance(:final label, :final usd) =>
    "$label: \$${usd.toStringAsFixed(2)} left",
  final UsageWindow window => _describeWindow(window, now),
};

String _describeWindow(UsageWindow window, DateTime now) {
  final amount = switch (window.unit) {
    UsageUnit.share => "${(window.fraction * 100).round()}% used",
    UsageUnit.usd =>
      "\$${window.used.toStringAsFixed(2)} of "
          "\$${window.max.toStringAsFixed(2)}",
    UsageUnit.requests =>
      "${window.used.round()} of ${window.max.round()} requests",
    UsageUnit.tokens =>
      "${window.used.round()} of ${window.max.round()} tokens",
  };
  final resets = window.resetsAt;
  return [
    "${window.label}: $amount",
    if (resets != null) "resets ${formatUntil(resets.difference(now))}",
  ].join(" · ");
}
