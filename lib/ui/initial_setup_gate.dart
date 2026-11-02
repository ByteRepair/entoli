import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../core/formatting.dart";
import "../domain/agent_browser.dart" show embeddedBrowserId;
import "../domain/download.dart";
import "../domain/rootfs.dart";
import "../providers.dart";
import "settings/browser_settings.dart";
import "settings/downloads.dart" show DownloadState;
import "settings/rootfs_downloads.dart";
import "widgets/app_mark.dart";

/// What a platform's first launch sets up ahead of the welcome tour: its
/// steps, in order, and how the bar counts them.
class SetupPlan {
  const SetupPlan(this.steps, {this.progress = const StepProgress()});

  final List<SetupStep> steps;
  final SetupProgress progress;
}

/// The plan this device runs. A phone gets Alpine as where commands run —
/// proot on Android, the emulator on iOS — and a desktop, whose agent drives
/// a browser the app launches rather than its own WebView, gets Helium as that
/// browser. Anywhere else nothing is set up.
final setupPlanProvider = Provider<SetupPlan>((ref) {
  if (ref.watch(prootAvailableProvider) ||
      ref.watch(deviceAbiProvider) == "ios") {
    return const SetupPlan([AlpineSetup()]);
  }
  final browser = ref.watch(agentBrowserProvider);
  if (browser.available && !browser.inApp) {
    return const SetupPlan([HeliumSetup()], progress: PlanProgress());
  }
  return const SetupPlan([]);
});

/// One thing a [SetupPlan] installs and makes the setting it is for. Picking
/// it is what makes it [done], so the page has no Next.
abstract class SetupStep {
  const SetupStep();

  /// What is installed, as the page names it.
  String get name;

  /// What it is for, after "Installing [name], so".
  String get purpose;

  /// Where it can be installed later, should it be skipped.
  String get settingsPage;

  /// The catalog it downloads through, and its id there.
  ProviderListenable<DownloadState> get downloads;
  String get downloadId;

  /// Whether its setting is picked. Watched.
  bool done(WidgetRef ref);

  /// Picks it where it is already on disk, otherwise starts the download.
  void start(WidgetRef ref);

  /// Picks it once its download lands, where the catalog does not already.
  void listen(WidgetRef ref) {}

  /// The line under the bar, given where its download is.
  String status(DownloadProgress? progress) => switch (progress) {
    null => "Starting…",
    DownloadProgress(unpacking: true) => "Unpacking $name…",
    DownloadProgress(total: > 0) =>
      "Downloading $name · ${formatSize(progress.received)} of "
          "${formatSize(progress.total)}",
    _ => "Downloading $name…",
  };
}

/// How the setup screen's bar reads.
abstract class SetupProgress {
  const SetupProgress();

  /// The bar from 0 to 1, or null to leave it indeterminate: [done] of
  /// [count] steps are behind [step], whose download is at [progress].
  double? fraction(
    SetupStep step,
    int done,
    int count,
    DownloadProgress? progress,
  );
}

/// The bar is the current step's download alone, filling again for each step
/// and indeterminate while there is nothing to count — before the first byte
/// and while it unpacks.
class StepProgress extends SetupProgress {
  const StepProgress();

  @override
  double? fraction(
    SetupStep step,
    int done,
    int count,
    DownloadProgress? progress,
  ) => progress?.bar;
}

/// One bar for the whole plan, each step an equal share of it and unpacking
/// [unpackShare] of that, so it only ever moves forward.
class PlanProgress extends SetupProgress {
  const PlanProgress({this.unpackShare = 0.2});

  final double unpackShare;

  @override
  double fraction(
    SetupStep step,
    int done,
    int count,
    DownloadProgress? progress,
  ) {
    final fetched = 1 - unpackShare;
    final within = switch (progress) {
      null => 0.0,
      // Unpacking reports no count of its own, so it holds where the
      // download left off until the step is done.
      DownloadProgress(unpacking: true) => fetched,
      _ => fetched * (progress.fraction ?? 0),
    };
    return (done + within) / count;
  }
}

class AlpineSetup extends SetupStep {
  const AlpineSetup();

  @override
  String get name => alpine.name;

  @override
  String get purpose => "the agent has a terminal to work in.";

  @override
  String get settingsPage => "Settings > Terminal";

  @override
  ProviderListenable<DownloadState> get downloads => rootfsDownloadsProvider;

  @override
  String get downloadId => alpine.id;

  @override
  bool done(WidgetRef ref) =>
      ref.watch(appSettingsProvider.select((s) => s.rootfsId != null));

  @override
  void start(WidgetRef ref) {
    if (ref.read(installedRootfsProvider).contains(alpine.id)) {
      ref.read(appSettingsProvider.notifier).setRootfs(alpine.id);
    } else {
      ref.read(rootfsDownloadsProvider.notifier).install(alpine);
    }
  }

  @override
  void listen(WidgetRef ref) =>
      ref.listen(installedRootfsProvider, (_, installed) {
        if (installed.contains(alpine.id)) {
          ref.read(appSettingsProvider.notifier).setRootfs(alpine.id);
        }
      });
}

/// The catalog's own rescan picks a first download, so there is nothing to
/// listen for.
class HeliumSetup extends SetupStep {
  const HeliumSetup();

  @override
  String get name => "Helium";

  @override
  String get purpose => "the agent has a browser to open pages in.";

  @override
  String get settingsPage => "Settings > Agent Browser";

  @override
  ProviderListenable<DownloadState> get downloads =>
      embeddedBrowserDownloadsProvider;

  @override
  String get downloadId => EmbeddedBrowserDownloads.id;

  @override
  bool done(WidgetRef ref) =>
      ref.watch(appSettingsProvider.select((s) => s.agentBrowser != null));

  @override
  void start(WidgetRef ref) {
    if (ref.read(agentBrowserProvider).embedded.installedVersion != null) {
      ref.read(appSettingsProvider.notifier).setAgentBrowser(embeddedBrowserId);
    } else {
      ref
          .read(embeddedBrowserDownloadsProvider.notifier)
          .install(EmbeddedBrowserDownloads.id);
    }
  }
}

/// Shows [SetupPage] over this device's [setupPlanProvider] while the welcome
/// tour is unseen and a step of it is not done. Otherwise it is [child] alone.
class InitialSetupGate extends ConsumerStatefulWidget {
  const InitialSetupGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<InitialSetupGate> createState() => _InitialSetupGateState();
}

class _InitialSetupGateState extends ConsumerState<InitialSetupGate> {
  /// Every step done or skipped. A skip is for this launch only: the tour
  /// being seen is what stops the page coming back, so a skip that is not
  /// followed by the tour asks again.
  bool _finished = false;

  @override
  Widget build(BuildContext context) {
    if (_finished ||
        ref.watch(appSettingsProvider.select((s) => s.licenceAccepted))) {
      return widget.child;
    }
    final plan = ref.watch(setupPlanProvider);
    if (plan.steps.every((s) => s.done(ref))) return widget.child;
    return SetupPage(
      plan: plan,
      onFinished: () => setState(() => _finished = true),
    );
  }
}

/// Runs [plan]'s steps one after another on one screen, each started when the
/// one before it is done or skipped, and says [onFinished] when none is left.
class SetupPage extends ConsumerStatefulWidget {
  const SetupPage({super.key, required this.plan, required this.onFinished});

  final SetupPlan plan;
  final VoidCallback onFinished;

  @override
  ConsumerState<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends ConsumerState<SetupPage> {
  final _skipped = <SetupStep>{};
  SetupStep? _started;

  void _start(SetupStep step) {
    _started = step;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) step.start(ref);
    });
  }

  @override
  Widget build(BuildContext context) {
    final steps = widget.plan.steps;
    final index = steps.indexWhere(
      (s) => !_skipped.contains(s) && !s.done(ref),
    );
    if (index < 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onFinished());
      return const Scaffold();
    }
    final step = steps[index];
    if (step != _started) _start(step);
    step.listen(ref);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = ref.watch(
      step.downloads.select((s) => s.active[step.downloadId]),
    );
    final failure = ref.watch(
      step.downloads.select((s) => s.failures[step.downloadId]),
    );
    final fraction = widget.plan.progress.fraction(
      step,
      index,
      steps.length,
      progress,
    );
    final status = step.status(progress);

    return Scaffold(
      body: SafeArea(
        child: Center(
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
                    "Initial setup",
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
                        value: fraction,
                        minHeight: 6,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      steps.length > 1
                          ? "Step ${index + 1} of ${steps.length} · $status"
                          : status,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
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
                          onPressed: () => setState(() => _skipped.add(step)),
                          child: const Text("Skip"),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: () => step.start(ref),
                          child: const Text("Retry"),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Skipped, it can be installed later under "
                      "${step.settingsPage}.",
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
