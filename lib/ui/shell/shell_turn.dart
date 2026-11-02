import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../domain/permission.dart" show addDirectoryName;
import "../../domain/room/room_state.dart";
import "../chat/activity/format.dart" show formatAge;
import "../chat/chat_controller.dart";
import "../chat/tool_ui/tools.dart";
import "../chat/widgets/running_pill.dart";
import "../chat/widgets/running_strip.dart" show runningSources;
import "shell_outbox.dart";
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

/// Where the turn surface's intents go: the one on screen.
class ShellTurnSlot {
  ShellTurnSurfaceState? current;
}

final shellTurnSlotProvider = Provider<ShellTurnSlot>((ref) => ShellTurnSlot());

class ShellTurnSurfaceState extends ConsumerState<ShellTurnSurface> {
  late final ShellOutbox _outbox = ref.read(shellOutboxProvider);
  late final ShellTurnSlot _slot = ref.read(shellTurnSlotProvider);

  /// The pills as last sent, which a `running` intent names one of by index.
  List<RunningThing> _running = const [];

  @override
  void dispose() {
    if (_slot.current == this) {
      _slot.current = null;
      _outbox.post(TurnSnapshot.none);
    }
    super.dispose();
  }

  /// What the shell's turn surface sent.
  Future<void> handle(String name, Map<String, Object?> args) async {
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
        if (approval == null) return;
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
  }

  @override
  Widget build(BuildContext context) {
    _slot.current = this;
    final view = widget.view;
    final notifier = widget.notifier;
    final chat = view.chat;
    final chatId = chat?.state.id;
    final alone = <RunningThing>[];
    final grouped = <RunningThing>[];
    if (chatId != null) {
      for (final source in runningSources) {
        for (final thing in source(ref, view, chatId)) {
          (thing.group == null ? alone : grouped).add(thing);
        }
      }
    }
    // Standing alone first, as the Flutter strip draws them.
    _running = [...alone, ...grouped];
    // One panel, the first turn waiting on answers, as `TurnQuestions` draws.
    final asked = view.roomPhase == RoomPhase.waitingOnYou
        ? view.questions.values.expand((q) => q).firstOrNull
        : null;
    _outbox.post(
      TurnSnapshot(
        resume: chat != null && chat.unfinished && !view.isRunning
            ? view.unfinishedNotice ??
                  "Unfinished turn from "
                      "${formatAge(DateTime.now().difference(chat.messages.last.createdAt))}"
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
          for (final say in view.steering) (id: say.id, line: _line(say)),
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
    final (icon, title) = approval.unsandboxed
        ? (Icons.shield_outlined, "Run without the sandbox?")
        : toolUIFor(approval.toolName).approval;
    return ApprovalSnapshot(
      id: approval.id,
      title: title,
      symbol: _symbolOf(icon) ?? "checkmark.shield",
      tool: approval.toolName,
      detail: approval.argumentsText ?? approval.argumentsJson,
      // A this-turn-only answer to a directory grant would lapse at the next
      // turn; a mirrored chat keeps it, its always answers being absent.
      allow: !(driver.rulesWritable && approval.toolName == addDirectoryName),
      chat: driver.rulesWritable,
      project: driver.rulesWritable,
    );
  }

  static final _space = RegExp(r"\s+");

  /// A say on one line, or the files it carries where it said nothing.
  static String _line(Message say) {
    final text = say.plainText.trim().replaceAll(_space, " ");
    if (text.isNotEmpty) return text;
    return say.files.map((f) => f.filename).join(", ");
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
