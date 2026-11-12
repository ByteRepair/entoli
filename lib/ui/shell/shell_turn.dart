import "package:entoli_glass/entoli_glass.dart";

import "../../app/running.dart" as app;
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/goal.dart";
import "../../domain/models.dart";
import "../../domain/room/room_state.dart";
import "../../app/chat_controller.dart";
import "../chat/widgets/approval_banner.dart";
import "../chat/widgets/running_pill.dart" show RunningThing;
import "../chat/widgets/running_strip.dart" show runningOf;
import "../../app/approvals.dart";
import "../../app/settings/spec.dart" show SettingReader, WidgetReader;
import "shell_outbox.dart";
import "glyphs.dart";
import "shell_answers.dart";

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
    this.voice = false,
  });

  final ChatViewState view;
  final TurnDriver notifier;
  final ValueChanged<Draft>? onWithdrawn;

  /// Voice mode's, over the chat page's: drawn while voice mode is up, and
  /// the chat page's while it is not.
  final bool voice;

  @override
  ConsumerState<ShellTurnSurface> createState() => ShellTurnSurfaceState();
}

/// The turn surface as the shell draws it, apart from any widget: the
/// snapshot of [view] — the resume offer, the goal, what is running, the says
/// the turn has not read, the calls waiting on an answer, the question — and
/// what the client says back, run through [driver]. Voice mode's widget and
/// the open chat's publisher (`ShellChat`) each hold one.
class TurnRunner implements TurnIntents {
  TurnRunner({required this.context, required this.onWithdrawn});

  /// Where a running pill opens its page.
  final BuildContext Function() context;

  /// A say taken back, put back into the composer; null where there is none.
  final ValueChanged<Draft>? onWithdrawn;

  ChatViewState _view = ChatViewState();
  TurnDriver? _driver;

  /// The pills as last sent, which a `running` intent names one of by index.
  List<RunningThing> _running = const [];

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
      final (:alone, :groups) = runningOf(reader, view, chatId);
      _running = [...alone, ...groups.values.expand((g) => g)];
    }
    // One panel, the first turn waiting on answers, as `TurnQuestions` draws.
    final asked = view.roomPhase == RoomPhase.waitingOnYou
        ? view.questions.values.expand((q) => q).firstOrNull
        : null;
    return TurnSnapshot(
      goal: goalSnapshotOf(chat?.goal),
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
    final at = context();
    if (id >= 0 && id < _running.length && at.mounted) _running[id].open(at);
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

/// Voice mode's turn surface: a [TurnRunner] over the page's view, drawn
/// while voice mode is up. (The open chat's is `ShellChat`'s.)
class ShellTurnSurfaceState extends ConsumerState<ShellTurnSurface> {
  late final ShellOutbox _outbox = ref.read(shellOutboxProvider);
  late final ShellAnswers _answers = ref.read(shellAnswersProvider);
  late final TurnRunner runner = TurnRunner(
    context: () => context,
    onWithdrawn: widget.onWithdrawn,
  );

  @override
  void initState() {
    super.initState();
    _answers.voiceOn.addListener(_resend);
  }

  @override
  void dispose() {
    _answers.voiceOn.removeListener(_resend);
    if (_answers.turn.release(runner)) _outbox.turn(TurnSnapshot());
    super.dispose();
  }

  bool get _drawn => widget.voice == _answers.voiceOn.value;

  /// Voice mode came or went: the one now drawn sends, nothing it watches
  /// having changed to rebuild it.
  void _resend() {
    if (!_drawn) _answers.turn.release(runner);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // The one beneath voice mode sends nothing: the shell draws the other.
    if (!_drawn) return const SizedBox.shrink();
    _answers.turn.take(runner);
    _outbox.turn(
      runner.snapshot(WidgetReader(ref), widget.view, widget.notifier),
    );
    return const SizedBox.shrink();
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
