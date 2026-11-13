import "package:flutter_riverpod/flutter_riverpod.dart";

import "../first_run.dart";
import "../settings/controller.dart";
import "../settings/spec.dart";
import "app_page.dart";

/// What this device sets up on its first launch, ahead of the welcome tour:
/// each step started when the one before it is done or skipped, a failed
/// one tried again or skipped for this launch.
class SetupAppPage extends AppPage {
  SetupAppPage(this.plan, {required this.onFinished});

  final SetupPlan plan;

  /// Every step done or skipped.
  final void Function() onFinished;

  final _skipped = <SetupStep>{};
  SetupStep? _started;
  ProviderSubscription<Object?>? _listening;
  bool _finished = false;

  @override
  String get address => "first-run-setup";

  /// It is left by finishing it, or by skipping what failed.
  @override
  bool held(SettingReader reader) => true;

  @override
  void closed() => _listening?.close();

  @override
  String title(SettingReader reader) => "Initial Setup";

  @override
  List<PageSection> sections(SettingReader reader) {
    final steps = plan.steps;
    final index = steps.indexWhere(
      (s) => !_skipped.contains(s) && !s.done(reader),
    );
    if (index < 0) {
      if (!_finished) {
        _finished = true;
        Future.microtask(onFinished);
      }
      return const [];
    }
    final step = steps[index];
    if (step != _started) {
      _started = step;
      _listening?.close();
      _listening = step.listen(this, app);
      Future.microtask(() => step.start(app));
    }
    final state = reader.watch(step.downloads);
    final progress = state.active[step.downloadId];
    final failure = state.failures[step.downloadId];
    final status = step.status(progress);
    if (failure != null) {
      return [
        PageSection(
          "failed",
          "${step.name} could not be installed",
          [
            noticeRow("failure", failure, tone: NoticeTone.warning),
            ActionController(
              part("retry", "Retry"),
              run: () async {
                step.start(app);
                return null;
              },
            ),
            ActionController(
              part("skip", "Skip"),
              secondary: true,
              run: () async {
                _skipped.add(step);
                changed();
                return null;
              },
            ),
          ],
          detail:
              "Skipped, it can be installed later under "
              "${step.settingsPage}.",
        ),
      ];
    }
    final fraction = plan.progress.fraction(
      step,
      index,
      steps.length,
      progress,
    );
    return [
      PageSection("step", "", [
        CollectionController<SetupStep>(
          part("step", step.name, hint: UiHint.info),
          items: [step],
          removable: false,
          describe: (_) => CollectionItem(
            "Installing ${step.name}",
            subtitle: "So ${step.purpose}",
            glyph: SettingGlyph.download,
            editable: false,
            takesImage: false,
            meters: [
              ItemMeter(
                steps.length > 1
                    ? "Step ${index + 1} of ${steps.length} · $status"
                    : status,
                fraction: fraction,
              ),
            ],
          ),
        ),
      ]),
    ];
  }
}
