import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;
import "package:uuid/uuid.dart";
import "package:entoli_core/model/formatting.dart";
import "package:entoli_core/model/log.dart";
import "package:entoli_core/model/agent_browser.dart" show embeddedBrowserId;
import "package:entoli_core/model/chat_log.dart";
import "package:entoli_core/model/download.dart";
import "package:entoli_core/model/models.dart";
import "package:entoli_core/model/project.dart";
import "package:entoli_core/model/rootfs.dart";

import "../providers.dart";
import "selection.dart";
import "downloads/browser_downloads.dart";
import "downloads/downloads.dart" show DownloadState;
import "downloads/rootfs_downloads.dart";

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

  /// Whether its setting is picked.
  ProviderListenable<bool> get done;

  /// Picks it where it is already on disk, otherwise starts the download.
  void start(Ref ref);

  /// Picks it once its download lands, where the catalog does not already:
  /// heard for as long as [ref] lives.
  void listen(Ref ref) {}

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
  ProviderListenable<bool> get done =>
      appSettingsProvider.select((s) => s.rootfsId != null);

  @override
  void start(Ref ref) {
    if (ref.read(installedRootfsProvider).contains(_default.id)) {
      ref.read(appSettingsProvider.notifier).setRootfs(_default.id);
    } else {
      ref.read(rootfsDownloadsProvider.notifier).install(_default);
    }
  }

  @override
  void listen(Ref ref) =>
      ref.listen<Set<String>>(installedRootfsProvider, (_, installed) {
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
  ProviderListenable<bool> get done =>
      appSettingsProvider.select((s) => s.agentBrowser != null);

  @override
  void start(Ref ref) {
    if (ref.read(agentBrowserProvider).embedded.installedVersion != null) {
      ref.read(appSettingsProvider.notifier).setAgentBrowser(embeddedBrowserId);
    } else {
      ref
          .read(embeddedBrowserDownloadsProvider.notifier)
          .install(EmbeddedBrowserDownloads.id);
    }
  }
}

/// Where the first launch's setup has got: the step it is on and where that
/// step's download is, or no step once every one is done or skipped.
typedef SetupState = ({
  SetupStep? step,
  int index,
  DownloadProgress? progress,
  String? failure,
});

/// The first launch's setup, run over this device's plan: each step started
/// when the one before it is done or skipped. A skip lasts as long as the
/// setup page does; the tour being finished is what stops it coming back.
final firstRunSetupProvider =
    NotifierProvider.autoDispose<FirstRunSetup, SetupState>(FirstRunSetup.new);

class FirstRunSetup extends Notifier<SetupState> {
  final _skipped = <SetupStep>{};
  SetupStep? _started;

  // Read, not watched: a rebuild would make a new notifier and lose the skips.
  late final SetupPlan plan = ref.read(setupPlanProvider);

  @override
  SetupState build() {
    for (final step in plan.steps) {
      step.listen(ref);
      ref.listen(step.done, (_, _) => state = _current());
      ref.listen(step.downloads, (_, _) => state = _current());
    }
    return _current();
  }

  SetupState _current() {
    final steps = plan.steps;
    final index = steps.indexWhere(
      (s) => !_skipped.contains(s) && !ref.read(s.done),
    );
    if (index < 0) {
      return (step: null, index: steps.length, progress: null, failure: null);
    }
    final step = steps[index];
    if (step != _started) {
      _started = step;
      // Out of the build: starting is a provider write.
      Future.microtask(() {
        if (ref.mounted) step.start(ref);
      });
    }
    final downloads = ref.read(step.downloads);
    return (
      step: step,
      index: index,
      progress: downloads.active[step.downloadId],
      failure: downloads.failures[step.downloadId],
    );
  }

  void retry() => state.step?.start(ref);

  void skip() {
    if (state.step case final step?) {
      _skipped.add(step);
      state = _current();
    }
  }
}

/// The tour's Done: the licence's tick stored, and a "Welcome to Entoli"
/// chat opened in the default project, whose library holds the skill. The
/// `/entoli-welcome-party` skill is its first message, so its instructions
/// reach every turn the way any skill message's do, its greeting under it.
Future<void> finishWelcomeTour(ProviderContainer app) async {
  final repo = app.read(chatRepositoryProvider);
  try {
    final chat = await repo.createChat(title: "Welcome to Entoli");
    final greeting = Message(
      id: const Uuid().v4(),
      role: MessageRole.assistant,
      createdAt: DateTime.now(),
      parts: const [MessagePart.text(text: _greeting)],
    );
    await repo.append(chat.state.id, [
      ...recordsOf([repo.composeUserPrompt("/entoli-welcome-party"), greeting]),
      ChatRecord.turnEnd(messageId: greeting.id, reason: TurnEnd.done),
    ]);
    app.read(selectedProjectProvider.notifier).select(localProject(null));
    app.read(selectedChatIdProvider.notifier).select(chat.state.id);
    app.invalidate(chatListProvider);
  } catch (e) {
    logFailure("welcome", "could not start the welcome chat", e);
  }
  await app.read(appSettingsProvider.notifier).setLicenceAccepted(true);
}

const _greeting =
    "Hello! Welcome to Entoli. I'm here to welcome you "
    "and help you customize the experience.\n\n"
    "By the way, if you ever want to talk to me again, just type "
    "/entoli-welcome-party and I'll respond.\n\n"
    "I have a few brief questions for you. What's your name?";
