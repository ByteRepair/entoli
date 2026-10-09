import "package:flutter/material.dart";

import "../widgets/nothing.dart";

/// The one answer an unreachable marketplace has, drawn the same whichever
/// page of the feature caught it — the list's tab and the preview — so the
/// two cannot drift into two different failures.
class Unreachable extends StatelessWidget {
  const Unreachable({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Nothing("Could not reach the marketplace."),
        TextButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text("Try again"),
          onPressed: onRetry,
        ),
      ],
    );
  }
}