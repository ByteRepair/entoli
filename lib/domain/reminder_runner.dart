import "package:uuid/uuid.dart";

import "agent_backend.dart";
import "chat_log.dart";
import "chat_meta.dart";
import "chat_repository.dart";
import "models.dart";
import "permission.dart";
import "project.dart";
import "reminder.dart";
import "turn_recorder.dart";

/// How a reminder's turn ended, worded for the completion notification.
enum ReminderOutcome { done, error, aborted }

/// What one reminder run produced.
typedef ReminderRunResult = ({String chatId, ReminderOutcome outcome, String snippet});

/// The seam between deciding a reminder is due and running its turn — what
/// [ReminderScheduler] actually needs, and what its tests stand in for.
abstract interface class ReminderRuns {
  Future<ReminderRunResult> run(Reminder reminder, List<String> projects);
}

/// Runs one reminder headlessly: a new chat in the reminder's project, the
/// prompt as its first turn, and nothing watching.
///
/// The recording duties are [ChatController]'s — this is the same job without
/// the UI. Skipping any of them shows up elsewhere: no `turnEnd` and every
/// later open offers to resume; no list invalidation and the chat is invisible
/// until restart; an unpinned `approveMode` and the turn parks on a banner
/// nobody will ever press.
class ReminderRunner implements ReminderRuns {
  ReminderRunner({
    required this.repo,
    required this.onListChanged,
    required this.onReminderFired,
  });

  final ChatRepository repo;

  /// The sidebar learns about the new chat when its first state lands.
  final void Function(String chatId) onListChanged;

  /// Stamps [Reminder.lastFiredAt] through whoever owns the list, before the
  /// turn runs.
  final Future<void> Function(Reminder reminder) onReminderFired;

  /// Run [reminder] now; the caller has already decided it is due. Fired is
  /// stamped before the turn starts, so a crash mid-turn costs a notification
  /// but never re-runs the whole prompt against the workspace.
  ///
  /// Returns the id of the chat the turn ran in, how it ended, and what the
  /// reply said — the completion notification's body.
  @override
  Future<ReminderRunResult> run(
    Reminder reminder,
    List<String> projects,
  ) async {
    final project = projectOrDefault(reminder.project, projects);
    final chat = await repo.createHeadlessChat(
      title: reminder.name,
      project: project,
      // Pinned rather than inherited: a later change of the app default must
      // not reach back into a chat that runs with nobody there to answer it.
      meta: ChatMeta(
        approveMode: ApproveMode.never,
        tempChatTtl: reminder.tempChatTtl,
      ),
    );
    await onReminderFired(reminder.copyWith(lastFiredAt: DateTime.now()));

    final prompt = repo.composeUserPrompt(reminder.prompt);
    final reply = Message(
      id: const Uuid().v4(),
      role: MessageRole.assistant,
      createdAt: DateTime.now(),
    );
    await repo.saveState(chat.state.copyWith(updatedAt: DateTime.now()));
    onListChanged(chat.state.id);

    final recorder = TurnRecorder(
      append: (records) => repo.append(chat.state.id, records),
    );
    recorder.open(reply.id);
    var reason = TurnEnd.done;
    try {
      await recorder.write(recordsOf([prompt, reply]));
      await for (final event in repo.sendPrompt(chat.state.id, prompt, headless: true)) {
        if (event is DoneEvent && event.aborted) {
          recorder.outcome ??= TurnEnd.aborted;
        }
        recorder.handle(event);
      }
    } catch (e) {
      recorder.handle(ErrorEvent("$e"));
    } finally {
      reason = await recorder.close();
      recorder.dispose();
    }
    final outcome = switch (reason) {
      TurnEnd.error => ReminderOutcome.error,
      TurnEnd.aborted => ReminderOutcome.aborted,
      TurnEnd.done => ReminderOutcome.done,
    };
    final snippet = recorder.parts
        .whereType<TextPart>()
        .map((p) => p.text)
        .join()
        .trim();
    return (chatId: chat.state.id, outcome: outcome, snippet: snippet);
  }
}
