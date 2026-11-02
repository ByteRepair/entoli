import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../domain/rootfs.dart";
import "../providers.dart";
import "../domain/agent_browser.dart" show embeddedBrowserId;
import "settings/browser_settings.dart";
import "settings/downloads.dart" show DownloadState;
import "settings/rootfs_downloads.dart";
import "widgets/app_mark.dart";
import "../core/formatting.dart";

/// One thing the first launch installs ahead of the welcome tour and makes the
/// setting it is for. Picking it is what takes it off [pending], so the page
/// has no Next: it is done when the setting is.
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

  /// Whether this device wants it and nothing is picked yet. Watched.
  bool pending(WidgetRef ref);

  /// Picks it where it is already on disk, otherwise starts the download.
  void start(WidgetRef ref);

  /// Picks it once its download lands, where the catalog does not already.
  void listen(WidgetRef ref) {}
}

/// Alpine as where commands run, wherever a Linux can — proot on Android, the
/// emulator on iOS — so a phone's terminal is Alpine before the user has had
/// to find the Terminal page.
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
  bool pending(WidgetRef ref) =>
      (ref.watch(prootAvailableProvider) ||
          ref.watch(deviceAbiProvider) == "ios") &&
      ref.watch(appSettingsProvider.select((s) => s.rootfsId == null));

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

/// Helium as the agent's browser, wherever the browser is one the app
/// launches rather than its own WebView — the desktops. The catalog's own
/// rescan picks a first download, so there is nothing to listen for.
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
  bool pending(WidgetRef ref) {
    final browser = ref.watch(agentBrowserProvider);
    return browser.available &&
        !browser.inApp &&
        ref.watch(appSettingsProvider.select((s) => s.agentBrowser == null));
  }

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

/// Shows [InitialSetupPage] for the first of [steps] this device still wants,
/// while the welcome tour is unseen. Everywhere else, and once the tour has
/// been seen, it is [child] alone.
class InitialSetupGate extends ConsumerStatefulWidget {
  const InitialSetupGate({super.key, required this.child});

  static const steps = <SetupStep>[AlpineSetup(), HeliumSetup()];

  final Widget child;

  @override
  ConsumerState<InitialSetupGate> createState() => _InitialSetupGateState();
}

class _InitialSetupGateState extends ConsumerState<InitialSetupGate> {
  /// Skip is for this launch only: the tour being seen is what stops the page
  /// coming back, so a skip that is not followed by the tour asks again.
  final _skipped = <SetupStep>{};

  @override
  Widget build(BuildContext context) {
    if (ref.watch(appSettingsProvider.select((s) => s.licenceAccepted))) {
      return widget.child;
    }
    final step = InitialSetupGate.steps
        .where((s) => !_skipped.contains(s) && s.pending(ref))
        .firstOrNull;
    if (step == null) return widget.child;
    return InitialSetupPage(
      key: ValueKey(step),
      step: step,
      onSkip: () => setState(() => _skipped.add(step)),
    );
  }
}

/// Installs [step] and picks it.
class InitialSetupPage extends ConsumerStatefulWidget {
  const InitialSetupPage({super.key, required this.step, required this.onSkip});

  final SetupStep step;
  final VoidCallback onSkip;

  @override
  ConsumerState<InitialSetupPage> createState() => _InitialSetupPageState();
}

class _InitialSetupPageState extends ConsumerState<InitialSetupPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  void _start() {
    if (mounted) widget.step.start(ref);
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.step;
    step.listen(ref);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final downloads = ref.watch(step.downloads);
    final progress = downloads.active[step.downloadId];
    final failure = downloads.failures[step.downloadId];
    final fraction =
        progress == null || progress.total <= 0 || progress.unpacking
        ? null
        : (progress.received / progress.total).clamp(0.0, 1.0);

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
                      progress == null
                          ? "Starting…"
                          : progress.unpacking
                          ? "Unpacking…"
                          : "${formatSize(progress.received)} of "
                                "${formatSize(progress.total)}",
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
                          onPressed: widget.onSkip,
                          child: const Text("Skip"),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: _start,
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
