import "package:clock/clock.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/provider_usage.dart";
import "../../app/provider_usage_words.dart";
import "../../providers.dart";

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
