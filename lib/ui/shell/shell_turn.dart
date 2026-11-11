import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/goal.dart";
import "../../domain/models.dart";
import "../../domain/room/room_state.dart";
import "../../app/chat_controller.dart";
import "../chat/widgets/approval_banner.dart";
import "../chat/widgets/resume_bar.dart";
import "../chat/widgets/running_pill.dart";
import "../chat/widgets/running_strip.dart" show runningOf;
import "../chat/widgets/steer_strip.dart";
import "../chat/widgets/turn_surface.dart" show approvalAnswers;
import "shell_outbox.dart";
import "shell_slots.dart";

/// [TurnSurface] drawn by the native shell, wired the same way: the resume
/// offer, the chat's goal, what is running, the says the turn has not read, and the calls
/// waiting on an answer go to the shell as a [TurnSnapshot], and what is
/// pressed there comes back to [handle]. The browser's prompts stay Flutter's,
/// beside this on the page.
class ShellTurnSurface extends ConsumerStatefulWidget {
  const ShellTurnSurface({
    super.key,
    required this.view,
    required this.notifier,
    this.onWithdrawn,
  });

  final ChatViewState view;
  final TurnDriver notifier;
  final ValueChanged<Draft>? onWithdrawn;

  @override
  ConsumerState<ShellTurnSurface> createState() => ShellTurnSurfaceState();
}

/// One of a stack: voice mode's is over the chat page's, and when it goes the
/// chat page's draws again.
class ShellTurnSurfaceState extends ConsumerState<ShellTurnSurface>
    implements TurnIntents {
  late final ShellOutbox _outbox = ref.read(shellOutboxProvider);
  late final ShellSlots _slots = ref.read(shellSlotsProvider);

  /// The pills as last sent, which a `running` intent names one of by index.
  List<RunningThing> _running = const [];

  @override
  void initState() {
    super.initState();
    _slots.turn.claim(this);
  }

  @override
  void dispose() {
    if (_slots.turn.leave(this)) {
      _outbox.turn(TurnSnapshot());
      // The one underneath, sent again: nothing it watches has changed, so
      // nothing else would rebuild it.
      if (_slots.turn.top case final ShellTurnSurfaceState under) {
        under._resend();
      }
    }
    super.dispose();
  }

  void _resend() {
    if (mounted) setState(() {});
  }

  @override
  Future<void> resume() => widget.notifier.resume();

  /// A button of the goal row, sent as the `/goal` command it is, as
  /// Flutter's `GoalStrip` sends it.
  @override
  Future<void> goal(GoalAction action) => widget.notifier.send(
    switch (action) {
      GoalAction.pause => const GoalPause(),
      GoalAction.resume => const GoalResume(),
      GoalAction.clear => const GoalClear(),
    }.text,
  );

  /// A pill, by its index in [_running].
  @override
  Future<void> running(int id) async {
    if (id >= 0 && id < _running.length && mounted) _running[id].open(context);
  }

  @override
  Future<void> queueSteer(String id) => widget.notifier.queueSteer(id);

  @override
  Future<void> withdraw(String id) async {
    final said = await widget.notifier.withdrawSteer(id);
    if (said != null) widget.onWithdrawn?.call(said);
  }

  @override
  Future<void> approve(String id, ApprovalAnswer answer) async {
    final approval = widget.view.approvals.values
        .expand((a) => a)
        .where((a) => a.id == id)
        .firstOrNull;
    if (approval == null) return;
    final response = switch (answer) {
      ApprovalAnswer.allow => ApprovalResponse.allow,
      ApprovalAnswer.chat => ApprovalResponse.alwaysAllowChat,
      ApprovalAnswer.project => ApprovalResponse.alwaysAllowProject,
      ApprovalAnswer.deny => ApprovalResponse.deny,
    };
    await widget.notifier.respondApproval(
      approval.id,
      response,
      approval:
          response == ApprovalResponse.alwaysAllowChat ||
              response == ApprovalResponse.alwaysAllowProject
          ? approval
          : null,
    );
  }

  /// One answer per question, null for each left unanswered.
  @override
  Future<void> answer(String id, List<String?> answers) =>
      widget.notifier.answerQuestions(id, answers);

  @override
  Widget build(BuildContext context) {
    // One underneath another sends nothing: the shell draws the top one.
    if (_slots.turn.top != this) return const SizedBox.shrink();
    final view = widget.view;
    final notifier = widget.notifier;
    final chat = view.chat;
    final chatId = chat?.state.id;
    // Standing alone first, as the Flutter strip draws them.
    if (chatId == null) {
      _running = const [];
    } else {
      final (:alone, :groups) = runningOf(ref, view, chatId);
      _running = [...alone, ...groups.values.expand((g) => g)];
    }
    // One panel, the first turn waiting on answers, as `TurnQuestions` draws.
    final asked = view.roomPhase == RoomPhase.waitingOnYou
        ? view.questions.values.expand((q) => q).firstOrNull
        : null;
    _outbox.turn(
      TurnSnapshot(
        goal: goalSnapshotOf(chat?.goal),
        resume: chat != null && chat.unfinished && !view.isRunning
            ? ResumeBar.lineOf(
                chat.messages.last.createdAt,
                notice: view.unfinishedNotice,
              )
            : null,
        running: [
          for (final (i, thing) in _running.indexed)
            RunningSnapshot(
              id: i,
              label: thing.label,
              tooltip: thing.tooltip,
              group: thing.group,
              symbol: _symbolOf(thing.icon),
              mono: thing.mono,
            ),
        ],
        steers: [
          for (final say in view.steering)
            SteerSnapshot(id: say.id, line: SteerStrip.line(say)),
        ],
        withdrawable: widget.onWithdrawn != null,
        approvals: [
          for (final approvals in view.approvals.values)
            for (final approval in approvals) _approval(approval, notifier),
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
      ),
    );
    return const SizedBox.shrink();
  }

  /// [ApprovalBanner]'s question, and the answers it offers.
  static ApprovalSnapshot _approval(ToolApproval approval, TurnDriver driver) {
    final (icon, title) = ApprovalBanner.headingOf(approval);
    final offers = approvalAnswers(driver, approval);
    return ApprovalSnapshot(
      id: approval.id,
      title: title,
      symbol: _symbolOf(icon) ?? "checkmark.shield",
      tool: approval.toolName,
      detail: approval.argumentsText ?? approval.argumentsJson,
      allow: offers.allow,
      chat: offers.always,
      project: offers.always,
    );
  }
}

/// The SF Symbol for one of the Material icons the turn surface draws, or
/// null where there is none to stand for it.
String? _symbolOf(IconData? icon) {
  if (icon == null) return null;
  if (icon == Icons.terminal) return "terminal";
  if (icon == Icons.public) return "globe";
  if (icon == Icons.travel_explore) return "safari";
  if (icon == Icons.visibility_off) return "eye.slash";
  if (icon == Icons.edit_outlined) return "pencil";
  if (icon == Icons.description_outlined) return "doc.text";
  if (icon == Icons.create_new_folder_outlined) return "folder.badge.plus";
  if (icon == Icons.shield_outlined) return "checkmark.shield";
  return null;
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
        label: goalStatusLabel(goal.status),
        summary: goalSummary(goal),
      );
