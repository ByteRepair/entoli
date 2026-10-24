import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/rootfs.dart";
import "../providers.dart";
import "settings/rootfs_downloads.dart";
import "widgets/app_mark.dart";
import "../core/formatting.dart";

/// Shows [InitialSetupPage] ahead of the welcome tour where a Linux can run —
/// proot on Android, the emulator on iOS — so a phone's terminal is Alpine
/// before the user has had to find the Terminal page. Everywhere else, and once
/// the tour has been seen, it is [child] alone.
class InitialSetupGate extends ConsumerStatefulWidget {
  const InitialSetupGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<InitialSetupGate> createState() => _InitialSetupGateState();
}

class _InitialSetupGateState extends ConsumerState<InitialSetupGate> {
  /// Skip is for this launch only: the tour being seen is what stops the page
  /// coming back, so a skip that is not followed by the tour asks again.
  bool _skipped = false;

  @override
  Widget build(BuildContext context) {
    final canHostALinux = ref.watch(prootAvailableProvider) ||
        ref.watch(deviceAbiProvider) == "ios";
    final pending = ref.watch(appSettingsProvider
        .select((s) => !s.licenceAccepted && s.rootfsId == null));
    if (!canHostALinux || !pending || _skipped) return widget.child;
    return InitialSetupPage(onSkip: () => setState(() => _skipped = true));
  }
}

/// Downloads Alpine and makes it where commands run. Picking it is what moves
/// the gate on, so there is no Next: the page is done when the setting is.
class InitialSetupPage extends ConsumerStatefulWidget {
  const InitialSetupPage({super.key, required this.onSkip});

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

  /// Already on disk, it is only picked; otherwise fetched, and picked by the
  /// listener in [build] when it lands.
  void _start() {
    if (!mounted) return;
    if (ref.read(installedRootfsProvider).contains(alpine.id)) {
      ref.read(appSettingsProvider.notifier).setRootfs(alpine.id);
    } else {
      ref.read(rootfsDownloadsProvider.notifier).install(alpine);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(installedRootfsProvider, (_, installed) {
      if (installed.contains(alpine.id)) {
        ref.read(appSettingsProvider.notifier).setRootfs(alpine.id);
      }
    });
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final progress = ref.watch(
        rootfsDownloadsProvider.select((s) => s.active[alpine.id]));
    final failure = ref.watch(
        rootfsDownloadsProvider.select((s) => s.failures[alpine.id]));
    final fraction = progress == null || progress.total <= 0 || progress.unpacking
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
                        ? "Installing ${alpine.name}, so the agent has a "
                            "terminal to work in."
                        : "${alpine.name} could not be installed.",
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 32),
                  if (failure == null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(value: fraction, minHeight: 6),
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
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ] else ...[
                    Text(
                      failure,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.error),
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
                      "Settings > Terminal.",
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
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
