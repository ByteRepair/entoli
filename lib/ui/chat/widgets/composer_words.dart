import "package:entoli_core/model/goal.dart";
import "package:entoli_core/model/wired_skill.dart";

import "../../../app/composer.dart";

/// What the composer says about its [ComposerMode].
extension ComposerModeWords on ComposerMode {
  /// The field's hint, where the mode has one of its own; a message's is the
  /// composer's. A callback has none: the field holding one is never empty.
  String? get hint => switch (this) {
    ComposerMode.shell => "Shell command",
    ComposerMode.callback || ComposerMode.message => null,
  };

  /// What the send button does, said as its tooltip. [queues] is
  /// [ComposerModel.queues]; [callback] is the callback typed.
  String sendLabel({required bool queues, WiredCall? callback}) =>
      switch (this) {
        ComposerMode.shell => "Run",
        ComposerMode.callback =>
          callback == null ? "Run" : callbackSendLabel(callback),
        ComposerMode.message =>
          queues ? "Send now, read at its next step" : "Send",
      };
}

/// What sending the callback [wired] does, as the send button says it.
String callbackSendLabel(WiredCall wired) => switch (wired.skill) {
  WiredSkill.compact => "Compact",
  WiredSkill.goal => switch (goalCommandOf(wired.arguments)) {
    GoalSet() => "Set goal",
    GoalResume() => "Resume goal",
    GoalPause() => "Pause goal",
    GoalClear() => "Clear goal",
    GoalShow() => "Show goal",
  },
};
