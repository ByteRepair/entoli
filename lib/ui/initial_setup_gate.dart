import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../app/first_run.dart";
import "widgets/app_mark.dart";

/// Whether this device's first-launch setup has a step left to run.
bool setupNeeded(WidgetRef ref) =>
    !ref.read(setupPlanProvider).steps.every((s) => ref.read(s.done));

/// The first launch's setup ([firstRunSetupProvider]) on one screen, left
/// only by finishing it: every step done or skipped pops it.
class SetupPage extends ConsumerWidget {
  const SetupPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(firstRunSetupProvider.select((s) => s.step == null), (_, done) {
      if (done) Navigator.of(context).pop();
    });
    final setup = ref.watch(firstRunSetupProvider);
    final step = setup.step;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: step == null ? const SizedBox.shrink() : _Step(setup, step),
        ),
      ),
    );
  }
}

class _Step extends ConsumerWidget {
  const _Step(this.setup, this.step);

  final SetupState setup;
  final SetupStep step;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final plan = ref.watch(firstRunSetupProvider.notifier).plan;
    final count = plan.steps.length;
    final failure = setup.failure;
    final status = step.status(setup.progress);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: AppMark(size: 88)),
              const SizedBox(height: 28),
              Text(
                "Initial Setup",
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text(
                failure == null
                    ? "Installing ${step.name}, so ${step.purpose}"
                    : "${step.name} could not be installed.",
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 32),
              if (failure == null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: plan.progress.fraction(
                      step,
                      setup.index,
                      count,
                      setup.progress,
                    ),
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  count > 1
                      ? "Step ${setup.index + 1} of $count · $status"
                      : status,
                  textAlign: TextAlign.center,
                  style: muted,
                ),
              ] else ...[
                Text(
                  failure,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: ref.read(firstRunSetupProvider.notifier).skip,
                      child: const Text("Skip"),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: ref.read(firstRunSetupProvider.notifier).retry,
                      child: const Text("Retry"),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  "Skipped, it can be installed later under "
                  "${step.settingsPage}.",
                  textAlign: TextAlign.center,
                  style: muted,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
