import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;

import "../core/formatting.dart";
import "../domain/agent_browser.dart" show embeddedBrowserId;
import "../domain/download.dart";
import "../domain/rootfs.dart";
import "../providers.dart";
import "downloads/browser_downloads.dart";
import "downloads/downloads.dart" show DownloadState;
import "downloads/rootfs_downloads.dart";
import "pages/app_page.dart";
import "settings/spec.dart";

/// What a platform's first launch sets up ahead of the welcome tour: its
/// steps, in order, and how the bar counts them.
class SetupPlan {
  const SetupPlan(this.steps, {this.progress = const StepProgress()});

  final List<SetupStep> steps;
  final SetupProgress progress;
}

/// The plan this device runs. A phone gets Alpine as where commands run —
/// proot on Android, the emulator on iOS. A desktop gets Helium as the
/// browser its agent drives, where the agent drives one the app launches
/// rather than its own WebView. Anywhere else nothing is set up. A CLI
/// program is none of it: it is installed when the provider that runs it is
/// connected, by the sign-in that connecting starts.
final setupPlanProvider = Provider<SetupPlan>((ref) {
  final linux = ref.watch(linuxHostProvider);
  if (linux.runsLinux) return SetupPlan([AlpineSetup(linux.catalog.first)]);
  final browser = ref.watch(agentBrowserProvider);
  return SetupPlan([
    if (browser.available && !browser.inApp) const HeliumSetup(),
  ], progress: const PlanProgress());
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
  bool done(SettingReader ref);

  /// Picks it where it is already on disk, otherwise starts the download.
  void start(SettingReader ref);

  /// Picks it once its download lands, where the catalog does not already:
  /// what [page] hears until it closes.
  ProviderSubscription<Object?>? listen(AppPage page, SettingReader ref) =>
      null;

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
  const AlpineSetup(this._default);

  /// The rootfs first startup installs: the one this device is offered.
  final Rootfs _default;

  @override
  String get name => _default.name;

  @override
  String get purpose => "the agent has a terminal to work in.";

  @override
  String get settingsPage => "Settings > Terminal";

  @override
  ProviderListenable<DownloadState> get downloads => rootfsDownloadsProvider;

  @override
  String get downloadId => _default.id;

  @override
  bool done(SettingReader ref) =>
      ref.watch(appSettingsProvider.select((s) => s.rootfsId != null));

  @override
  void start(SettingReader ref) {
    if (ref.read(installedRootfsProvider).contains(_default.id)) {
      ref.read(appSettingsProvider.notifier).setRootfs(_default.id);
    } else {
      ref.read(rootfsDownloadsProvider.notifier).install(_default);
    }
  }

  @override
  ProviderSubscription<Object?> listen(AppPage page, SettingReader ref) =>
      page.listen<Set<String>>(installedRootfsProvider, (_, installed) {
        if (installed.contains(_default.id)) {
          ref.read(appSettingsProvider.notifier).setRootfs(_default.id);
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
  bool done(SettingReader ref) =>
      ref.watch(appSettingsProvider.select((s) => s.agentBrowser != null));

  @override
  void start(SettingReader ref) {
    if (ref.read(agentBrowserProvider).embedded.installedVersion != null) {
      ref.read(appSettingsProvider.notifier).setAgentBrowser(embeddedBrowserId);
    } else {
      ref
          .read(embeddedBrowserDownloadsProvider.notifier)
          .install(EmbeddedBrowserDownloads.id);
    }
  }
}
