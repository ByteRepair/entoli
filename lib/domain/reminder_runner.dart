import "package:clock/clock.dart";

import "chat_repository.dart";
import "project.dart";
import "reminder.dart";

/// How a reminder's turn ended, worded for the completion notification.
enum ReminderOutcome { done, error, aborted }

/// What one reminder run produced.
typedef ReminderRunResult = ({String chatId, ReminderOutcome outcome, String snippet});

/// The seam between deciding a reminder is due and running its turn — what
/// [ReminderScheduler] actually needs, and what its tests stand in for.
abstract interface class ReminderRuns {
  Future<ReminderRunResult> run(Reminder reminder, List<String> projects);
}

/// Drives a reminder's turn through the same [ChatController] the UI uses,
/// so a turn started headlessly is the one the user sees if they open the chat
/// while it is running. The implementation lives in the UI layer; the domain
/// only knows the interface.
abstract interface class ReminderTurnDriver {
  Future<({ReminderOutcome outcome, String snippet})> send(String chatId, String prompt);
}

/// Creates the chat, stamps the reminder fired, and hands the turn to a
/// [ReminderTurnDriver]. The driver — wired from the UI layer — runs the turn
/// through [ChatController], so the controller's `isRunning` and the backend's
/// `runningTurns` are always in sync. There is one path that drives a turn, not
/// two, and the desync a separate recorder caused (a concurrent turn, a
/// missed `interruptLiveTurns`) cannot happen.
class ReminderRunner implements ReminderRuns {
  ReminderRunner({
    required this.repo,
    required this.driver,
    required this.onListChanged,
    required this.onReminderFired,
    this.clock = const Clock(),
  });

  final ChatRepository repo;
  final ReminderTurnDriver driver;
  final Clock clock;

  /// The sidebar learns about the new chat when its first state lands.
  final void Function(String chatId) onListChanged;

  /// Stamps [Reminder.lastFiredAt] through whoever owns the list, before the
  /// turn runs.
  final Future<void> Function(Reminder reminder) onReminderFired;

  @override
  Future<ReminderRunResult> run(
    Reminder reminder,
    List<String> projects,
  ) async {
    final project = projectOrDefault(reminder.project, projects);
    final chat = await repo.createChat(
      title: reminder.name,
      project: project,
      meta: reminder.meta,
    );
    await onReminderFired(reminder.copyWith(lastFiredAt: clock.now()));
    onListChanged(chat.state.id);
    final result = await driver.send(chat.state.id, reminder.prompt);
    return (chatId: chat.state.id, outcome: result.outcome, snippet: result.snippet);
  }
}
