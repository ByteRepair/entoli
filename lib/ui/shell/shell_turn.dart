import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../domain/room/room_state.dart";
import "../chat/chat_controller.dart";
import "../chat/widgets/approval_banner.dart";
import "../chat/widgets/resume_bar.dart";
import "../chat/widgets/running_pill.dart";
import "../chat/widgets/running_strip.dart" show runningOf;
import "../chat/widgets/steer_strip.dart";
import "../chat/widgets/turn_surface.dart" show approvalAnswers;
import "shell_outbox.dart";
import "shell_slots.dart";
import "snapshots.dart";

/// [TurnSurface] drawn by the native shell, wired the same way: the resume
/// offer, what is running, the says the turn has not read, and the calls
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
    implements ShellSurface {
  late final ShellOutbox _outbox = ref.read(shellOutboxProvider);
  late final ShellSlots _slots = ref.read(shellSlotsProvider);

  /// The pills as last sent, which a `running` intent names one of by index.
  List<RunningThing> _running = const [];

  @override
  void initState() {
    super.initState();
    _slots.claim(ShellConcern.turn, this);
  }

  @override
  void dispose() {
    if (_slots.leave(ShellConcern.turn, this)) {
      _outbox.post(TurnSnapshot.none);
      // The one underneath, sent again: nothing it watches has changed, so
      // nothing else would rebuild it.
      if (_slots.top(ShellConcern.turn)
          case final ShellTurnSurfaceState under) {
        under._resend();
      }
    }
    super.dispose();
  }

  void _resend() {
    if (mounted) setState(() {});
  }

  /// What the shell's turn surface sent.
  @override
  Future<Object?> handle(String name, Map<String, Object?> args) async {
    final notifier = widget.notifier;
    String id() => args["id"]! as String;
    switch (name) {
      case "resume":
        await notifier.resume();
      case "running":
        final at = (args["id"]! as num).toInt();
        if (at >= 0 && at < _running.length && mounted) {
          _running[at].open(context);
        }
      case "queueSteer":
        await notifier.queueSteer(id());
      case "withdraw":
        final said = await notifier.withdrawSteer(id());
        if (said != null) widget.onWithdrawn?.call(said);
      case "approve":
        final approval = widget.view.approvals.values
            .expand((a) => a)
            .where((a) => a.id == id())
            .firstOrNull;
        if (approval == null) return null;
        final answer = switch (args["answer"]) {
          "allow" => ApprovalResponse.allow,
          "chat" => ApprovalResponse.alwaysAllowChat,
          "project" => ApprovalResponse.alwaysAllowProject,
          _ => ApprovalResponse.deny,
        };
        await notifier.respondApproval(
          approval.id,
          answer,
          approval:
              answer == ApprovalResponse.alwaysAllowChat ||
                  answer == ApprovalResponse.alwaysAllowProject
              ? approval
              : null,
        );
      case "answer":
        // One per question, null for each left unanswered.
        final answers = [
          for (final answer in args["answers"]! as List<Object?>)
            answer as String?,
        ];
        await notifier.answerQuestions(id(), answers);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // One underneath another sends nothing: the shell draws the top one.
    if (_slots.top(ShellConcern.turn) != this) return const SizedBox.shrink();
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
    _outbox.post(
      TurnSnapshot(
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
            (id: say.id, line: SteerStrip.line(say)),
        ],
        withdrawable: widget.onWithdrawn != null,
        approvals: [
          for (final approvals in view.approvals.values)
            for (final approval in approvals) _approval(approval, notifier),
        ],
        question: asked == null
            ? null
            : (id: asked.id, questions: asked.questions),
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
