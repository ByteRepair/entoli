import "package:clock/clock.dart";

import "chat_repository.dart";
import "models.dart" show Chat, CompletionKind;
import "project.dart";
import "reminder_alarms.dart";
import "../core/log.dart";
import "trigger.dart";

/// How a trigger's turn ended, worded for the completion notification.
enum TriggerOutcome { done, error, aborted }

/// What one trigger run produced. [targetGone] is whether the fire found
/// its target chat deleted — no turn ran; the trigger was disarmed by the
/// manager, which owns the bookkeeping, and the fire's own notification
/// was worded by the runner.
typedef TriggerRunResult = ({
  String chatId,
  TriggerOutcome outcome,
  String snippet,
  bool targetGone,
});

/// The seam between deciding a trigger is due and running its turn — what
/// [TriggerManager] actually needs, and what its tests stand in for.
/// [reason] is the kind's own words for why the fire happened, appended to
/// the prompt rather than sent beside it: the log says why a turn started.
abstract interface class TriggerRuns {
  Future<TriggerRunResult> run(
    Trigger trigger,
    String reason,
    List<String> projects,
  );
}

/// Drives a trigger's turn through the same [ChatController] the UI uses, so
/// a turn started headlessly is the one the user sees if they open the chat
/// while it is running. The implementation lives in the UI layer; the domain
/// only knows the interface.
abstract interface class TriggerTurnDriver {
  Future<({TriggerOutcome outcome, String snippet})> send(
    String chatId,
    String prompt,
  );
}

/// Creates the chat or finds the target, stamps the trigger fired, and hands
/// the turn to a [TriggerTurnDriver]. The driver — wired from the UI layer —
/// runs the turn through [ChatController], so the controller's `isRunning`
/// and the backend's `runningTurns` are always in sync. There is one path
/// that drives a turn, not two, and the desync a separate recorder caused (a
/// concurrent turn, a missed `interruptLiveTurns`) cannot happen.
///
/// **The target is the trigger's [Trigger.chatId]**, not a policy here: null
/// means a new headless chat — what a schedule the user set is, and what
/// reminders always were — and a chat id means the conversation that
/// registered the trigger carries on in it. A watched chat's turns run under
/// its own meta, [Trigger.meta] being for the new-chat case alone; the turn
/// is not `headless` there, since `ask_user` has an owner.
class TriggerRunner implements TriggerRuns {
  TriggerRunner({
    required this.repo,
    required this.driver,
    required this.alarms,
    required this.onListChanged,
    required this.onTriggerFired,
    this.clock = const Clock(),
  });

  final ChatRepository repo;
  final TriggerTurnDriver driver;

  /// Notifies the one thing no one else words: a fire whose target chat has
  /// gone, which is no turn's completion. Completions are the manager's.
  final ReminderAlarms alarms;
  final Clock clock;

  /// The sidebar learns about the new chat when its first state lands.
  final void Function(String chatId) onListChanged;

  /// Stamps [Trigger.lastFiredAt] through whoever owns the list, before the
  /// turn runs.
  final Future<void> Function(Trigger trigger) onTriggerFired;

  @override
  Future<
    ({String chatId, TriggerOutcome outcome, String snippet, bool targetGone})
  >
  run(Trigger trigger, String reason, List<String> projects) async {
    final target = trigger.chatId;
    return target == null
        ? _runNewChat(trigger, reason, projects)
        : _runIntoChat(trigger, reason, target);
  }

  /// The headless half: the prompt the trigger set, the reason a line under
  /// it, in a chat made for the fire.
  Future<
    ({String chatId, TriggerOutcome outcome, String snippet, bool targetGone})
  >
  _runNewChat(Trigger trigger, String reason, List<String> projects) async {
    final project = projectOrDefault(trigger.project, projects);
    final chat = await repo.createChat(
      title: trigger.title,
      project: project,
      meta: trigger.meta,
    );
    await onTriggerFired(trigger.copyWith(lastFiredAt: clock.now()));
    onListChanged(chat.state.id);
    final result = await driver.send(
      chat.state.id,
      prompted(trigger.prompt, reason, member: trigger.member),
    );
    return (
      chatId: chat.state.id,
      outcome: result.outcome,
      snippet: result.snippet,
      targetGone: false,
    );
  }

  /// The chat-side half. The chat is validated before anything is stamped: a
  /// trigger naming a chat that has been deleted (a swept temp chat among
  /// them) is the manager's to disarm — the fire answers for itself with a
  /// notification, worded here where the words the disarm needs are, and
  /// runs nothing. Nothing re-points the prompt at some other conversation.
  ///
  /// A same-chat fire while the user's own turn runs queues behind it on the
  /// room rather than being swallowed by Send's refusal — the driver awaits
  /// the running turn before speaking.
  Future<
    ({String chatId, TriggerOutcome outcome, String snippet, bool targetGone})
  >
  _runIntoChat(Trigger trigger, String reason, String chatId) async {
    Chat? chat;
    try {
      chat = await repo.openChat(chatId);
    } on StateError {
      // The store's own "no chat" — the deleted-target case this arm exists
      // for.
      chat = null;
    } catch (e) {
      // Anything else — a disk error, a storage blip — is not "gone": the
      // trigger stays armed for its next slot, with a line saying what
      // happened rather than a disarm and a lie about deletion.
      logFailure(
        "triggers",
        "could not open target chat; the fire is skipped",
        e,
      );
      return (
        chatId: chatId,
        outcome: TriggerOutcome.error,
        snippet: "",
        targetGone: false,
      );
    }
    if (chat == null) {
      logFailure("triggers", "target chat is gone; disarming", chatId);
      await alarms.notify(
        title: trigger.title,
        body:
            "The chat this trigger runs in no longer exists, so it was "
            "switched off.",
      );
      return (
        chatId: chatId,
        outcome: TriggerOutcome.error,
        snippet: "",
        targetGone: true,
      );
    }
    await onTriggerFired(trigger.copyWith(lastFiredAt: clock.now()));
    final result = await driver.send(
      chatId,
      prompted(trigger.prompt, reason, member: trigger.member),
    );
    return (
      chatId: chatId,
      outcome: result.outcome,
      snippet: result.snippet,
      targetGone: false,
    );
  }

  /// The one wording of "the fire, and what set it off": the prompt (its
  /// mention first, where the trigger names a member — the composer resolves
  /// the sigil'd reference from the documents and the room routes it like
  /// any message sent), then the kind's reason in a line below. The tool's
  /// schema description names this shape, not a literal of a reason's own
  /// words.
  static String prompted(String prompt, String reason, {String? member}) => [
    if (member != null) "${CompletionKind.agent.trigger}$member",
    prompt,
    if (reason.isNotEmpty) "($reason)",
  ].join("\n\n");
}
