import "package:entoli_glass/entoli_glass.dart";

import "../../app/running.dart" as app;
import "package:flutter/material.dart";

import "../../domain/goal.dart";
import "../../domain/models.dart";
import "../../domain/room/room_state.dart";
import "../../app/transcript/activities/todo.dart" show TodoWords;
import "../../domain/todo.dart";
import "../../app/chat_controller.dart";
import "../chat/widgets/approval_banner.dart";
import "../chat/widgets/running_strip.dart" show openRunning;
import "../../app/approvals.dart";
import "../../app/settings/spec.dart" show SettingReader;
import "glyphs.dart";

/// The turn surface as the shell draws it, apart from any widget: the
/// snapshot of [view] — the resume offer, the goal, the task list, what is
/// running, the says the turn has not read, the calls waiting on an answer,
/// the question — and what the client says back, run through [driver]. Voice mode's session and
/// the open chat's publisher (`ShellChat`) each hold one.
class TurnRunner implements TurnIntents {
  TurnRunner({
    required this.context,
    required this.onWithdrawn,
    this.openDetail,
  });

  /// Opens a running thing's detail the frontend's own way, where it has
  /// one: the native conversation's sheet.
  final void Function(app.OpensDetail detail)? openDetail;

  /// Where a running pill opens its page.
  final BuildContext Function() context;

  /// A say taken back, put back into the composer; null where there is none.
  final ValueChanged<Draft>? onWithdrawn;

  ChatViewState _view = ChatViewState();
  TurnDriver? _driver;

  /// The pills as last sent, which a `running` intent names one of by index.
  List<app.RunningThing> _running = const [];

  /// [view]'s snapshot, read through [reader], and the turn intents now act
  /// on it through [driver].
  TurnSnapshot snapshot(
    SettingReader reader,
    ChatViewState view,
    TurnDriver driver,
  ) {
    _view = view;
    _driver = driver;
    final chat = view.chat;
    final chatId = chat?.state.id;
    // Standing alone first, as the Flutter strip draws them.
    if (chatId == null) {
      _running = const [];
    } else {
      final (:alone, :groups) = app.runningOf(reader, view, chatId);
      _running = [...alone, ...groups.values.expand((g) => g)];
    }
    // One panel, the first turn waiting on answers, as `TurnQuestions` draws.
    final asked = view.roomPhase == RoomPhase.waitingOnYou
        ? view.questions.values.expand((q) => q).firstOrNull
        : null;
    return TurnSnapshot(
      goal: goalSnapshotOf(chat?.goal),
      todo: todoSnapshotOf(chat?.todos),
      resume: chat != null && chat.unfinished && !view.isRunning
          ? ResumeSnapshot(
              startedAt: chat.messages.last.createdAt.millisecondsSinceEpoch,
              notice: view.unfinishedNotice,
            )
          : null,
      running: [
        for (final (i, thing) in _running.indexed)
          RunningSnapshot(
            id: i,
            kind: switch (thing.kind) {
              app.RunningKind.browser => RunningKind.browser,
              app.RunningKind.job => RunningKind.job,
              app.RunningKind.subAgent => RunningKind.subAgent,
            },
            name: thing.name,
            hidden: thing.hidden,
          ),
      ],
      steers: [
        for (final say in view.steering)
          SteerSnapshot(
            id: say.id,
            text: say.plainText.trim(),
            files: [for (final f in say.files) f.filename],
          ),
      ],
      withdrawable: onWithdrawn != null,
      approvals: [
        for (final approvals in view.approvals.values)
          for (final approval in approvals) _approval(approval, driver),
      ],
      question: asked == null
          ? null
          : QuestionRequest(
              id: asked.id,
              questions: [
                for (final q in asked.questions)
                  QuestionSnapshot(
                    question: q.question,
                    summary: q.summary,
                    options: [
                      for (final o in q.options)
                        QuestionOption(
                          label: o.label,
                          detail: o.detail,
                          answer: o.answer,
                        ),
                    ],
                  ),
              ],
            ),
    );
  }

  @override
  Future<void> resume() async => _driver?.resume();

  /// A button of the goal row, sent as the `/goal` command it is, as
  /// Flutter's `GoalStrip` sends it.
  @override
  Future<void> goal(GoalAction action) async => _driver?.send(
    switch (action) {
      GoalAction.pause => const GoalPause(),
      GoalAction.resume => const GoalResume(),
      GoalAction.clear => const GoalClear(),
    }.text,
  );

  /// A pill, by its index in [_running].
  @override
  Future<void> running(int id) async {
    if (id < 0 || id >= _running.length) return;
    final thing = _running[id];
    final opener = openDetail;
    if (thing.opens case final app.OpensDetail detail when opener != null) {
      return opener(detail);
    }
    final at = context();
    if (at.mounted) openRunning(at, thing);
  }

  @override
  Future<void> queueSteer(String id) async => _driver?.queueSteer(id);

  @override
  Future<void> withdraw(String id) async {
    final said = await _driver?.withdrawSteer(id);
    if (said != null) onWithdrawn?.call(said);
  }

  @override
  Future<void> approve(String id, ApprovalAnswer answer) async {
    final driver = _driver;
    final approval = _view.approvals.values
        .expand((a) => a)
        .where((a) => a.id == id)
        .firstOrNull;
    if (approval == null || driver == null) return;
    await driver.answer(approval, switch (answer) {
      ApprovalAnswer.allow => ApprovalResponse.allow,
      ApprovalAnswer.chat => ApprovalResponse.alwaysAllowChat,
      ApprovalAnswer.project => ApprovalResponse.alwaysAllowProject,
      ApprovalAnswer.deny => ApprovalResponse.deny,
    });
  }

  /// One answer per question, null for each left unanswered.
  @override
  Future<void> answer(String id, List<String?> answers) async =>
      _driver?.answerQuestions(id, answers);

  /// [ApprovalBanner]'s question, and the answers it offers.
  static ApprovalSnapshot _approval(ToolApproval approval, TurnDriver driver) {
    final (icon, title) = ApprovalBanner.headingOf(approval);
    final offers = approvalAnswers(driver, approval);
    return ApprovalSnapshot(
      id: approval.id,
      title: title,
      glyph: glyphOf(icon) ?? Glyph.shield,
      tool: approval.toolName,
      detail: approval.argumentsText ?? approval.argumentsJson,
      allow: offers.allow,
      chat: offers.always,
      project: offers.always,
    );
  }
}

/// [goal] as the shell's goal row draws it, or null for none.
GoalSnapshot? goalSnapshotOf(ChatGoal? goal) => goal == null
    ? null
    : GoalSnapshot(
        objective: goal.objective,
        phase: switch (goal.status) {
          GoalStatus.active => GoalPhase.active,
          GoalStatus.paused => GoalPhase.paused,
          GoalStatus.met => GoalPhase.met,
          GoalStatus.blocked => GoalPhase.blocked,
        },
        reason: goal.reason,
      );

/// The task list row's snapshot of [list]; null or empty draws none.
TodoSnapshot? todoSnapshotOf(TodoList? list) => list == null || list.isEmpty
    ? null
    : TodoSnapshot(
        items: [
          for (final item in list.items)
            TodoItemSnapshot(
              content: item.content,
              phase: switch (item.status) {
                TodoStatus.pending => TodoPhase.pending,
                TodoStatus.inProgress => TodoPhase.inProgress,
                TodoStatus.completed => TodoPhase.completed,
              },
            ),
        ],
        done: list.done,
        headline: list.headline,
      );
