import "package:clock/clock.dart";

import "../core/log.dart";
import "chat_repository.dart";
import "models.dart";
import "project.dart";
import "reminder_alarms.dart";
import "trigger.dart";

/// How a trigger's turn ended, worded for the completion notification.
enum TriggerOutcome { done, error, aborted }

/// What one trigger run produced.
typedef TriggerRunResult = ({String chatId, TriggerOutcome outcome, String snippet});

/// The seam between deciding a trigger is due and running its turn — what
/// [TriggerManager] actually needs, and what its tests stand in for.
/// [reason] is the kind's own words for why the fire happened, appended to
/// the prompt rather than sent beside it: the log says why a turn started.
abstract interface class TriggerRuns {
  Future<TriggerRunResult> run(Trigger trigger, String reason, List<String> projects);
}

/// Drives a trigger's turn through the same [ChatController] the UI uses, so
/// a turn started headlessly is the one the user sees if they open the chat
/// while it is running. The implementation lives in the UI layer; the domain
/// only knows the interface.
abstract interface class TriggerTurnDriver {
  Future<({TriggerOutcome outcome, String snippet})> send(String chatId, String prompt);
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

  /// The port's notify half — no scheduling — is how a fire answers for
  /// itself when it cannot reach its chat, and how a headless one completes.
  final ReminderAlarms alarms;
  final Clock clock;

  /// The sidebar learns about the new chat when its first state lands.
  final void Function(String chatId) onListChanged;

  /// Stamps [Trigger.lastFiredAt] through whoever owns the list, before the
  /// turn runs.
  final Future<void> Function(Trigger trigger) onTriggerFired;

  @override
  Future<TriggerRunResult> run(
    Trigger trigger,
    String reason,
    List<String> projects,
  ) async {
    final target = trigger.chatId;
    if (target != null) return _runIntoChat(trigger, reason, target);
    final project = projectOrDefault(trigger.project, projects);
    final chat = await repo.createChat(
      title: trigger.name,
      project: project,
      meta: trigger.meta,
    );
    await onTriggerFired(trigger.copyWith(lastFiredAt: clock.now()));
    onListChanged(chat.state.id);
    final prompt = reason.isEmpty ? trigger.prompt : "${trigger.prompt}\n\n($reason)";
    final result = await driver.send(chat.state.id, prompt);
    return (chatId: chat.state.id, outcome: result.outcome, snippet: result.snippet);
  }

  /// The chat-side half. The chat is validated before anything is stamped: a
  /// trigger naming a chat that has been deleted (a swept temp chat among
  /// them) is disarmed rather than re-pointed, a notification saying so where
  /// the fire had a name to say. Nothing re-runs the prompt somewhere else —
  /// the conversation it answers is the one it named.
  ///
  /// A same-chat fire while the user's own turn runs queues behind it on the
  /// room rather than being swallowed by Send's refusal — the driver awaits
  /// the running turn before speaking.
  Future<TriggerRunResult> _runIntoChat(
      Trigger trigger, String reason, String chatId) async {
    Chat? chat;
    try {
      chat = (await repo.loadState(chatId)) == null ? null : await repo.openChat(chatId);
    } catch (_) {
      chat = null;
    }
    if (chat == null) {
      logFailure("triggers", "target chat is gone; disarming", chatId);
      await alarms.notify(
        title: trigger.name.isEmpty ? "Trigger" : trigger.name,
        body: "The chat this trigger runs in no longer exists, so it was "
            "switched off.",
      );
      await onTriggerFired(
          trigger.copyWith(enabled: false, clearNextFireAt: true, lastFiredAt: null));
      return (
        chatId: chatId,
        outcome: TriggerOutcome.error,
        snippet: "",
      );
    }
    await onTriggerFired(trigger.copyWith(lastFiredAt: clock.now()));
    final prompt = reason.isEmpty ? trigger.prompt : "${trigger.prompt}\n\n($reason)";
    final result = await driver.send(chatId, prompt);
    return (chatId: chatId, outcome: result.outcome, snippet: result.snippet);
  }
}