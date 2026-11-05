import "package:clock/clock.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/provider_usage.dart";
import "../../providers.dart";
import "../chat/activity/format.dart";

/// A configured provider's allowances, one bar each, under its row. Nothing
/// at all while it is being asked or where the provider says nothing, which
/// is most of them: a row that grows a bar when it can is quieter than one
/// that says "unknown" for every provider that cannot.
class ProviderUsageView extends ConsumerWidget {
  const ProviderUsageView(this.providerId, {super.key});

  final String providerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usages =
        ref.watch(providerUsageProvider(providerId)).value ?? const [];
    if (usages.isEmpty) return const SizedBox.shrink();
    final now = clock.now();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final usage in usages)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(describeUsage(usage, now)),
                  // A balance has nothing to measure it against, so no bar.
                  if (usage is UsageWindow) ...[
                    const SizedBox(height: 2),
                    LinearProgressIndicator(
                      value: usage.fraction,
                      semanticsLabel: usage.label,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

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
