import "package:flutter/material.dart";

import "../widgets/empty_pane.dart";

/// The one answer an unreachable marketplace has, on the list and on a
/// preview alike, so the two cannot drift into two different failures.
class Unreachable extends StatelessWidget {
  const Unreachable({super.key, required this.onRetry, this.detail});

  final VoidCallback onRetry;

  /// What was caught: a timeout is not a 500.
  final String? detail;

  @override
  Widget build(BuildContext context) => EmptyPane(
    icon: Icons.cloud_off_outlined,
    title: "Could not reach the marketplace.",
    detail: detail ?? "",
    action: TextButton.icon(
      icon: const Icon(Icons.refresh),
      label: const Text("Try again"),
      onPressed: onRetry,
    ),
  );
}
