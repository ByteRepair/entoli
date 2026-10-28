import "dart:convert";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart" show ProviderListenable;
import "package:path/path.dart" as p;

import "../../../core/config.dart"
    show instructionBlockHeader, instructionFileName;
import "../../fonts.dart";
import "../../widgets/scrolling.dart" show ScrollFollow;
import "../../skills/skill_install_preview.dart";
import "../../../domain/ask.dart";
import "../../../domain/file_tools.dart";
import "../../../domain/models.dart";
import "../../../domain/room/room_state.dart" show ChatViewState;
import "../../../domain/shell.dart" show bashToolName;
import "../../../domain/tool_arg.dart";
import "../../../providers.dart";
import "../../../domain/shell_job.dart";
import "../../workspace/text_viewer_page.dart";
import "../chat_controller.dart" show chatControllerProvider;
import "../mirror_controller.dart" show mirrorChatControllerProvider;
import "../sub_agent_transcript.dart" show subAgentLiveProvider;
import "running_strip.dart" show JobSheet;
import "code_block.dart" show codeBlockDecoration, codeBlockStyle;
import "message_bubble.dart" show MessageBubble, StreamingCaret;
import "shell_run.dart" show ShellCommandText;
import "../../../domain/web_search.dart" show websearchToolName;

/// What the model did before it answered, on a line of its own above the
/// reply: thinking, and tool runs. Frameless, so it reads as a label until it
/// is tapped, which opens the detail in a drawer.
///
/// While the block is being written its tail streams under the label, so the
/// thinking is read as it happens rather than only once it is over.
class ThinkingLabel extends StatelessWidget {
  const ThinkingLabel({super.key, required this.part, this.at, this.isLive = false});

  final ReasoningPart part;

  /// Where [part] sits in its message, which is what an open drawer finds it
  /// by as the block grows. Null draws the drawer from [part] as it was.
  final int? at;

  /// The model is writing this block right now.
  final bool isLive;

  String get _text {
    if (isLive) return "Thinking…";
    final ms = part.durationMs;
    // Neither streamed nor timed: an older conversation, or an aborted turn.
    return ms == null ? "View thinking" : "Thought for ${formatThinkingTime(ms)}";
  }

  ActivityView? _follow(LiveMessage now, WidgetRef _) {
    final parts = now.message?.parts;
    final at = this.at;
    if (parts == null || at == null || at >= parts.length) return null;
    final part = parts[at];
    if (part is! ReasoningPart) return null;
    final live = now.running && part.durationMs == null;
    return (
      title: live ? "Thinking…" : "Thinking",
      status: null,
      sections: [(label: null, body: part.text, isError: false)],
      live: live,
    );
  }

  void _open(BuildContext context) => showActivitySheet(
        context,
        title: isLive ? "Thinking…" : "Thinking",
        icon: Icons.psychology_outlined,
        sections: [(label: null, body: part.text, isError: false)],
        follow: _follow,
      );

  @override
  Widget build(BuildContext context) {
    final label = _Label(
      icon: Icons.psychology_outlined,
      text: _text,
      onTap: () => _open(context),
    );
    if (!isLive || part.text.trim().isEmpty) return label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        label,
        _ThoughtTail(text: part.text, onTap: () => _open(context)),
      ],
    );
  }
}

/// The last few lines of a thought being written, faded at the top so it
/// reads as the end of something longer. The drawer has the whole of it.
class _ThoughtTail extends StatelessWidget {
  const _ThoughtTail({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  static const _lines = 4;

  /// What is laid out per delta. Only the tail is ever shown, and laying out
  /// a long thought whole every frame to show its last lines is the cost.
  static const _tailChars = 800;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontStyle: FontStyle.italic,
    );
    final lineHeight = (style?.fontSize ?? 12) * (style?.height ?? 1.4);
    final tail = text.length > _tailChars
        ? text.substring(text.length - _tailChars)
        : text;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(_labelPadX + _labelIcon + _labelGap, 0, _labelPadX, 6),
        child: ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black],
            stops: [0, 0.45],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: SizedBox(
            height: lineHeight * _lines,
            width: double.infinity,
            // Reversed so the newest line is the one held in view.
            child: SingleChildScrollView(
              reverse: true,
              physics: const NeverScrollableScrollPhysics(),
              child: Text(tail.trim(), style: style),
            ),
          ),
        ),
      ),
    );
  }
}

class ToolLabel extends StatelessWidget {
  const ToolLabel({super.key, this.call, this.result, this.running = false})
      : assert(call != null || result != null);

  final ToolCall? call;

  /// Null while the tool is still running.
  final ToolResult? result;

  /// Whether this label is for the tool the turn is currently running. Only
  /// true for the live label of a waiting turn that has already said something
  /// — the spinner below the message handles the no-text-yet case.
  final bool running;

  bool get _failed =>
      (result?.returnCode ?? 0) != 0 ||
      (result?.violations.isNotEmpty ?? false);

  @override
  Widget build(BuildContext context) {
    final name = call?.name;
    final showSpinner = running && result == null;
    final verb = result == null ? "Using tool" : "Used tool";
    final outcome = result?.permissionOutcome;
    return _Label(
      icon: _failed ? Icons.error_outline : Icons.terminal,
      text: name == null
          ? verb
          : outcome == null
              ? "$verb: $name"
              : "$verb: $name — $outcome",
      isError: _failed,
      // A running tool gets a spinner instead of a static icon, so the turn
      // shows it is busy even after the model has said something. The spinner
      // below the message handles the no-text-yet case, so this only shows
      // where that one doesn't.
      iconWidget: showSpinner
          ? Padding(
              padding: const EdgeInsets.all(1),
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      onTap: () => showActivitySheet(
        context,
        title: name ?? "Tool",
        icon: Icons.terminal,
        mono: true,
        command: _command(call),
        status: _status(call, result),
        sections: _sections(call, result, null),
        follow: (now, _) {
          final run = _runIn(now.message, call?.id ?? result!.callId);
          if (run == null) return null;
          final live = now.running && run.result == null;
          return (
            title: null,
            status: _status(run.call ?? call, run.result),
            sections: _sections(run.call ?? call, run.result, live ? now.shellOutput : null),
            live: live,
          );
        },
      ),
    );
  }

  /// A `bash` call's command, set apart the way a `!` message is.
  static String? _command(ToolCall? call) => call?.name == bashToolName
      ? stringArg(call?.argumentsJson, "command")
      : null;

  static ActivityStatus? _status(ToolCall? call, ToolResult? result) {
    if (call?.name != bashToolName) return null;
    if (result == null) return (text: "Running", isError: false);
    return (text: "Exit code ${result.returnCode}", isError: result.returnCode != 0);
  }

  static List<ActivitySection> _sections(
      ToolCall? call, ToolResult? result, String? printing) {
    final run = _runSections(call, result, printing: printing);
    final command = _command(call);
    return [
      // The command is drawn above; what is left of the arguments, if any.
      if (command != null) ...[
        (label: "Arguments", body: _argsBesides(call, "command"), isError: false),
        ...run.skip(1),
      ] else
        ...run,
      if (result != null && result.violations.isNotEmpty)
        (label: "Sandbox", body: result.violations.join("\n"), isError: true),
    ];
  }

  static String? _argsBesides(ToolCall? call, String key) {
    final args = decodeArgs(call?.argumentsJson);
    if (args == null) return null;
    final rest = {...args}..remove(key);
    return rest.isEmpty ? null : jsonEncode(rest);
  }
}

/// The call [id] names in [message], if it has been written there yet.
ToolCall? toolCallIn(Message? message, String id) => _runIn(message, id)?.call;

/// The call [id] names in [message] and the result answering it, as the
/// message now stands. Null where neither is in it.
({ToolCall? call, ToolResult? result})? _runIn(Message? message, String id) {
  if (message == null) return null;
  ToolCall? call;
  for (final part in message.parts) {
    if (part is ToolCallPart && part.toolCall.id == id) call = part.toolCall;
  }
  final result = message.toolResults[id];
  if (call == null && result == null) return null;
  return (call: call, result: result);
}

/// The drawer a tool run opens, whether it was drawn as a label or as a diff.
/// The Output section is cut below the rendered-instructions header where a
/// nested read appended one to the result: the drawer says what the file held,
/// and the instructions block — the model's reading, not the file's — lives
/// in its own record's drawer instead. Cut at the last occurrence, since the
/// block is appended at the tail. [printing] is what a running command has
/// printed so far, standing in for the output it has not returned yet.
List<ActivitySection> _runSections(ToolCall? call, ToolResult? result, {String? printing}) {
  final output = result?.output;
  String? shown = output ?? printing;
  if (output != null) {
    final at = output.lastIndexOf(instructionBlockHeader);
    if (at >= 0) shown = output.substring(0, at).trimRight();
  }
  return [
    (label: "Arguments", body: call?.argumentsText ?? call?.argumentsJson, isError: false),
    (label: "Output", body: shown, isError: false),
    (label: "Error", body: result?.exceptionInfo, isError: true),
    (label: "Outcome", body: result?.permissionOutcome, isError: false),
  ];
}

/// The instruction files a turn was the first to read into the model's
/// context — the up-front `AGENTS.md` load, or a nested one a file read
/// pulled in. One label per read, on the part that records it; the drawer
/// says what was read and where each file sat, never what the files said —
/// the content rides the per-turn system prompt and the read results, and is
/// the model's, not the conversation's.
class InstructionsLabel extends StatelessWidget {
  const InstructionsLabel({super.key, required this.part});

  final InstructionsPart part;

  @override
  Widget build(BuildContext context) {
    final files = part.files;
    final text = switch (files) {
      [final only] => "Read ${_basenameOf(only.path)}",
      final several => "Read ${several.length} instruction files",
    };
    return _Label(
      icon: Icons.description_outlined,
      text: text,
      onTap: () => showActivitySheet(
        context,
        title: "Instructions",
        sections: [
          for (final ref in files)
            (
              label: instructionKindPhrase(ref.kind),
              body: ref.path,
              isError: false,
            ),
        ],
      ),
    );
  }
}

/// What a single file's label names it by: the bare name where it is an
/// instruction file proper, the path when it is anything else — a nested one
/// is clearer as where it sits.
String _basenameOf(String path) =>
    p.basename(path) == instructionFileName ? instructionFileName : path;

/// What a recorded decision reads as, on a label's text and in its drawer's
/// Outcome section. The wording is the shared contract of the two — one
/// helper so they cannot disagree. Null where the result carries none: a
/// log from before the field existed, or a call nothing stood in front of.
String? _outcomeText(
    PermissionSource? by, List<PermissionTier> tiers, PermissionDecision? decided) {
  final allowed = switch (decided) {
    PermissionDecision.deny => "denied",
    null => null,
    _ => "allowed",
  };
  final where = switch (tiers) {
    [] => "",
    [PermissionTier.once] => " by you",
    [PermissionTier.chat] => " by this chat's rules",
    [PermissionTier.project] => " by the project's rules",
    [PermissionTier.defaultProject] => " by the app's rules",
    [PermissionTier.runtime] => " by a rule granted this turn",
    _ => " by the rules of ${tiers.map(_tierName).join(" and ")}",
  };
  return switch (by) {
    PermissionSource.rule => tiers.isEmpty
        ? null
        : "${allowed ?? "allowed"}$where",
    PermissionSource.classifier =>
      decided == null ? "by the classifier" : "${allowed ?? "allowed"} by the classifier",
    PermissionSource.human => "${allowed ?? "allowed"}$where",
    PermissionSource.mode => "${allowed ?? "allowed"} by the approve mode",
    PermissionSource.parse =>
      "${allowed ?? "allowed"} by the command parse",
    PermissionSource.rerun => "rerun unconfined after you approved",
    _ => null,
  };
}

String _tierName(PermissionTier tier) => switch (tier) {
      PermissionTier.chat => "this chat",
      PermissionTier.project => "the project",
      PermissionTier.defaultProject => "the app",
      _ => tier.name,
    };

extension on ToolResult {
  /// The outcome wording for this run's recorded decision — the label's
  /// clause and the drawer's Outcome section. Null where nothing was
  /// recorded, which is the old-log case and the ungated call's.
  String? get permissionOutcome {
    final wording = _outcomeText(decidedBy, decidedTier, decided);
    if (wording == null) return null;
    // An old log records who decided but not what — the exit code is the
    // only witness there, and it is right except for the banner answers,
    // which the approval part records on its own.
    if (decided == null && returnCode != 0) return null;
    return wording;
  }
}

/// A file write or edit drawn as red/green diff lines rather than a label,
/// where the change is small enough to read at a glance. The before/after
/// comes from the call alone — the arguments carry it — so this draws from
/// what conv.jsonl already holds and nothing is captured at execution time.
/// Past the budget it declines (null), leaving the ordinary [ToolLabel].
class DiffTextLabel extends StatelessWidget {
  static const budget = 20;

  const DiffTextLabel({
    super.key,
    required this.call,
    required this.result,
    required this.removed,
    required this.added,
  });

  final ToolCall call;
  final ToolResult result;
  final List<String> removed;
  final List<String> added;

  static DiffTextLabel? forRun(ToolCall call, ToolResult? result) {
    if (result == null || result.returnCode != 0) return null;
    if (call.argumentsJson != null && call.argumentsJson!.length > maxArgsLength) return null;
    final beforeAfter = _beforeAfter(call);
    if (beforeAfter == null) return null;
    final (before, after) = beforeAfter;
    final (removed, added) = _diff(before, after);
    if (removed.isEmpty && added.isEmpty) return null;
    if (removed.length + added.length > budget) return null;
    return DiffTextLabel(call: call, result: result, removed: removed, added: added);
  }

  static const maxArgsLength = 20000;

  /// The before and after a file tool's call names, or null where the call is
  /// another tool's or its arguments are not the shape the tool takes.
  static (String, String)? _beforeAfter(ToolCall call) {
    if (call.name == writeToolName) {
      final args = writeArgsFrom(call.argumentsJson);
      return args == null ? null : ("", args.content);
    }
    if (call.name == editToolName) {
      final args = editArgsFrom(call.argumentsJson);
      return args == null ? null : (args.oldString, args.newString);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final red = theme.colorScheme.error;
    final green = theme.brightness == Brightness.dark
        ? const Color(0xFF3FB950)
        : const Color(0xFF1A7F37);
    final verb = call.name == writeToolName ? "Wrote" : "Edited";
    final title = "$verb ${call.argumentsText ?? ""}".trim();
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: () => showActivitySheet(
          context,
          title: title,
          mono: true,
          sections: _runSections(call, result),
        ),
        style: _labelStyle(theme.colorScheme.onSurfaceVariant, _labelText(theme)),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.description_outlined, size: _labelIcon),
                const SizedBox(width: _labelGap),
                Text(title),
              ]),
              const SizedBox(height: 4),
              for (final line in removed)
                Text("- $line", style: TextStyle(fontFamily: monoFamily, fontSize: 12.5, color: red)),
              for (final line in added)
                Text("+ $line", style: TextStyle(fontFamily: monoFamily, fontSize: 12.5, color: green)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lines the two texts do not share, found by trimming what they do: the
/// common head, then the common tail. Whatever is left of [before] is
/// removed; of [after], added. Interior structure is not looked for, so a
/// reordering reads as remove-and-add — and the budget answers for the worst
/// of it, which is why the same lines can come back in either order.
///
/// The empty text splits to one empty line, which is no line anyone wrote —
/// dropped when it is all the trimming left, kept where it is a real blank
/// line beside others.
(List<String>, List<String>) _diff(String before, String after) {
  final oldLines = before.split("\n");
  final newLines = after.split("\n");
  var start = 0;
  while (start < oldLines.length && start < newLines.length && oldLines[start] == newLines[start]) {
    start++;
  }
  var endOld = oldLines.length;
  var endNew = newLines.length;
  while (endOld > start && endNew > start && oldLines[endOld - 1] == newLines[endNew - 1]) {
    endOld--;
    endNew--;
  }
  final removed = oldLines.sublist(start, endOld);
  final added = newLines.sublist(start, endNew);
  if (removed.singleEmpty) removed.clear();
  if (added.singleEmpty) added.clear();
  return (removed, added);
}

extension on List<String> {
  /// Just the one empty line — the whole of a split empty string, or a middle
  /// the trim left with nothing else in it.
  bool get singleEmpty => length == 1 && this[0].isEmpty;
}

/// A question the model put to the user, once it is history. The panel that
/// asked it is gone by then, so this reads the question back out of the call
/// and the answer out of the result that closed it.
class AskLabel extends StatefulWidget {
  const AskLabel({super.key, required this.call, this.result});

  final ToolCall call;

  /// Null while the panel is still on screen.
  final ToolResult? result;

  @override
  State<AskLabel> createState() => _AskLabelState();
}

class _AskLabelState extends State<AskLabel> {
  late List<AskQuestion> _questions;
  late List<String?> _answers;

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void didUpdateWidget(AskLabel old) {
    super.didUpdateWidget(old);
    if (old.call.argumentsJson != widget.call.argumentsJson ||
        old.result?.output != widget.result?.output) {
      _read();
    }
  }

  /// Parsed once and kept. Every visible message is rebuilt on every streamed
  /// delta, and the JSON behind an asked question never changes.
  void _read() {
    _questions = askQuestionsFrom(widget.call.argumentsJson);
    _answers = askAnswersFrom(widget.result?.output);
  }

  @override
  Widget build(BuildContext context) {
    // Named `ask_user` but with nothing askable in it: the model got the shape
    // wrong and was told so, which is an ordinary failed tool run and carries
    // the reason a question label would drop.
    if (_questions.isEmpty) {
      return ToolLabel(call: widget.call, result: widget.result);
    }
    return _Label(
      icon: Icons.help_outline,
      text: _questions.length == 1
          ? _questions.single.question
          : "Asked ${_questions.length} questions",
      onTap: () => showActivitySheet(
        context,
        title: "Asked the user",
        sections: [
          for (var i = 0; i < _questions.length; i++)
            (
              label: _questions[i].question,
              body: _answers.elementAtOrNull(i) ?? "Not answered",
              isError: false,
            ),
        ],
      ),
    );
  }
}

/// A permission banner the turn raised, once it is history: what was asked
/// (the call, worded as the banner worded it) and what was answered. The
/// panel that asked is gone by then; this reads the recorded part. A
/// superseded answer reads in place — "asked" without an answer is a turn
/// that ended with the banner up, which the deny-on-end recorded instead.
class ApprovalLabel extends StatelessWidget {
  const ApprovalLabel({super.key, required this.part, this.result});

  final ApprovalPart part;

  /// The result the call it asked about produced, carrying the outcome —
  /// what decided the call — whose wording rides on the label and in the
  /// drawer. Null where the call never produced one: a deny, an answer that
  /// raced the turn out.
  final ToolResult? result;

  @override
  Widget build(BuildContext context) {
    // Raw answers, not the mapped wording: "deny" is what the enum records.
    final denied =
        part.answer == "deny" || part.answer == "asked";
    final answer = switch (part.answer) {
      "asked" => "asked (never answered)",
      "allow" => "allowed",
      "alwaysAllowChat" => "allowed, always in this chat",
      "alwaysAllowProject" => "allowed, always in this project",
      "deny" => "denied",
      _ => part.answer,
    };
    // The outcome names what stood behind the call's fate, the answer what
    // was pressed: on an "always" answer the two say the same thing, so the
    // clause is left off there — and on a re-prompt's, whose result records
    // the rerun the answer went on to, the first banner would wear the
    // rerun's outcome.
    final outcome = result?.permissionOutcome;
    final clause = switch (part.answer) {
      "alwaysAllowChat" || "alwaysAllowProject" || "asked" => null,
      // A re-prompt's result records the rerun the answer went on to; the
      // first banner must not wear that rerun's outcome.
      _ when part.deniedDirs.isNotEmpty => null,
      _ => outcome,
    };
    return _Label(
      icon: denied ? Icons.gpp_maybe_outlined : Icons.gpp_good_outlined,
      text: clause == null
          ? "Permission: ${part.toolName} — $answer"
          : "Permission: ${part.toolName} — $answer ($clause)",
      isError: denied,
      onTap: () => showActivitySheet(
        context,
        title: "Permission",
        mono: true,
        sections: [
          (
            label: part.toolName,
            body: part.argumentsText,
            isError: false,
          ),
          if (part.deniedDirs.isNotEmpty)
            (
              label: "Sandbox dirs granted",
              body: part.deniedDirs.join("\n"),
              isError: false,
            ),
          (label: "Answer", body: answer, isError: false),
          if (outcome != null)
            (label: "Outcome", body: outcome, isError: false),
        ],
      ),
    );
  }
}

/// A `task` call: the sub-agent that ran, and behind the drawer its own
/// transcript as it is written — the same labels a reply has — with the text
/// it returned standing in where there is no transcript to show. Reads the
/// agent name and prompt out of the call's arguments.
class TaskLabel extends StatelessWidget {
  const TaskLabel({super.key, required this.chatId, required this.call, this.result});

  /// Whose `subagents/` the transcript is under.
  final String chatId;

  final ToolCall call;

  /// Null while the sub-agent is still running.
  final ToolResult? result;

  @override
  Widget build(BuildContext context) {
    final agent = stringArg(call.argumentsJson, "agent") ?? "task";
    final prompt = stringArg(call.argumentsJson, "prompt") ?? "";
    final failed = (result?.returnCode ?? 0) != 0;
    return _Label(
      icon: failed ? Icons.error_outline : Icons.account_tree_outlined,
      text: result == null
          ? "Running sub-agent @$agent"
          : "Sub-agent @$agent ${failed ? "failed" : "finished"}",
      isError: failed,
      onTap: () => showTaskSheet(context,
          chatId: chatId,
          callId: call.id,
          agent: agent,
          prompt: prompt,
          result: result),
    );
  }
}

/// A sub-agent's drawer: its prompt, and its transcript as it is written,
/// with the text it returned standing in where there is no transcript.
/// Follows the run where [context] has an [ActivitySource] holding its call.
Future<void> showTaskSheet(
  BuildContext context, {
  required String chatId,
  required String callId,
  required String agent,
  required String prompt,
  ToolResult? result,
}) {
  final sub = (chatId: chatId, callId: callId);
  return showActivitySheet(
    context,
    title: "Sub-agent @$agent",
    icon: Icons.account_tree_outlined,
    sections: _taskSections(prompt, result, transcript: false),
    follow: (now, ref) {
      final run = _runIn(now.message, callId);
      if (run == null) return null;
      final transcript = ref.watch(subAgentLiveProvider(sub)).message;
      return (
        title: null,
        status: null,
        sections: _taskSections(prompt, run.result,
            transcript: transcript?.parts.isNotEmpty ?? false),
        live: now.running && run.result == null,
      );
    },
    below: (ref) {
      final live = ref.watch(subAgentLiveProvider(sub));
      final message = live.message;
      if (message == null || message.parts.isEmpty) return null;
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        // Its own source, so a label in the transcript opens a drawer
        // that follows the sub-agent rather than the parent's reply.
        child: ActivitySource(
          live: subAgentLiveProvider(sub),
          child: MessageBubble(
            chatId: chatId,
            message: message,
            isWaiting: live.running,
          ),
        ),
      );
    },
  );
}

/// The Output is the transcript's text joined, so it is left out where the
/// transcript is drawn.
List<ActivitySection> _taskSections(String prompt, ToolResult? result,
        {required bool transcript}) =>
    [
      (label: "Prompt", body: prompt, isError: false),
      if (!transcript) (label: "Output", body: result?.output, isError: false),
      (label: "Error", body: result?.exceptionInfo, isError: true),
    ];

/// A `bash` call that started a background job: the job's state rather than
/// the call's, since the call was over the moment the job started. Its drawer
/// is the job's — the log as it grows while it runs, then what the chat kept
/// of it and a way to the whole log while that is still in the workspace.
class JobLabel extends ConsumerWidget {
  const JobLabel({super.key, required this.chatId, required this.call});

  final String chatId;
  final ToolCall call;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mirrored = ref.watch(isMirroredChatProvider(chatId));
    final ProviderListenable<ChatViewState> chat = mirrored
        ? mirrorChatControllerProvider(chatId)
        : chatControllerProvider(chatId);
    final end = ref.watch(chat.select((v) => v.chat?.jobEnds[call.id]));
    final command = stringArg(call.argumentsJson, "command") ?? "";
    final line = firstLine(command);
    // A mirror's jobs are the other device's, and only their ends reach it.
    final jobs = mirrored ? null : ref.watch(agentBackendProvider).jobsOf(chatId);

    Widget ended() {
      final status = jobStatus(end, mirrored: mirrored);
      return _Label(
        icon: status.isError ? Icons.error_outline : Icons.terminal,
        text: "Background job ${status.text.toLowerCase()}: $line",
        isError: status.isError,
        onTap: () => showActivityCard<void>(
          context,
          (_) => ActivityCard(
            title: end == null ? "Background job" : "Background job ${end.jobId}",
            icon: Icons.terminal,
            command: command,
            status: status,
            mono: true,
            actions: [
              if (!mirrored)
                _OpenLog(
                  path: ref.read(appConfigProvider).fs.path.join(
                      ref.read(appConfigProvider).workspaceDir(chatId,
                          project: ref.read(chat).chat?.state.project),
                      end?.log ?? backgroundLog(call.id)),
                ),
            ],
            sections: [
              (label: "Output", body: end?.tail, isError: false),
            ],
          ),
        ),
      );
    }

    if (end != null || jobs == null) return ended();
    return ValueListenableBuilder<List<ShellJob>>(
      valueListenable: jobs.jobs,
      builder: (context, list, _) {
        final job = list.where((j) => j.callId == call.id).firstOrNull;
        if (job == null) return ended();
        return _Label(
          icon: Icons.terminal,
          text: "Running in the background: $line",
          iconWidget: Padding(
            padding: const EdgeInsets.all(1),
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          onTap: () =>
              showActivityCard<void>(context, (_) => JobSheet(jobs: jobs, job: job)),
        );
      },
    );
  }
}

/// How a job ended, for a card's status line. No [end] is a job that ended
/// with the app, or on a [mirrored] chat, one whose end has not reached it.
ActivityStatus jobStatus(JobEnd? end, {bool mirrored = false}) {
  if (end == null) {
    return (text: mirrored ? "Not heard from" : "Ended with the app", isError: false);
  }
  final code = end.exitCode;
  if (code == null) return (text: "Stopped", isError: false);
  return (text: "Exited with code $code", isError: code != 0);
}

/// Opens a job's whole log in the file viewer, while the workspace still has
/// it.
class _OpenLog extends StatelessWidget {
  const _OpenLog({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final fs = ProviderScope.containerOf(context).read(appConfigProvider).fs;
    return FutureBuilder<bool>(
      future: fs.file(path).exists(),
      builder: (context, there) {
        final has = there.data ?? false;
        final button = TextButton(
          onPressed: !has
              ? null
              : () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) =>
                      TextViewerPage(path: path, name: fs.path.basename(path)))),
          child: const Text("Open log"),
        );
        if (has || there.connectionState != ConnectionState.done) return button;
        return Tooltip(
            message: "The log is no longer in the workspace", child: button);
      },
    );
  }
}

/// A `websearch` or `webfetch` call, once it is history: the query or URL
/// read out of the call's arguments, and what came back behind the drawer.
class WebLabel extends StatelessWidget {
  const WebLabel({super.key, required this.call, this.result});

  final ToolCall call;
  final ToolResult? result;

  @override
  Widget build(BuildContext context) {
    final search = call.name == websearchToolName;
    final what = stringArg(call.argumentsJson, search ? "query" : "url") ?? "";
    final failed = (result?.returnCode ?? 0) != 0;
    final verb = search
        ? (result == null ? "Searching" : "Searched")
        : (result == null ? "Fetching" : "Fetched");
    return _Label(
      icon: failed
          ? Icons.error_outline
          : search
              ? Icons.travel_explore_outlined
              : Icons.language_outlined,
      text: "$verb: $what",
      isError: failed,
      onTap: () => showActivitySheet(
        context,
        title: search ? "Web search" : "Web fetch",
        icon: search ? Icons.travel_explore_outlined : Icons.language_outlined,
        mono: true,
        sections: _sections(search, what, result),
        follow: (now, _) {
          final run = _runIn(now.message, call.id);
          if (run == null) return null;
          return (
            title: null,
            status: null,
            sections: _sections(search, what, run.result),
            live: now.running && run.result == null,
          );
        },
      ),
    );
  }

  static List<ActivitySection> _sections(bool search, String what, ToolResult? result) => [
        (label: search ? "Query" : "URL", body: what, isError: false),
        (label: search ? "Results" : "Content", body: result?.output, isError: false),
        (label: "Error", body: result?.exceptionInfo, isError: true),
      ];
}

/// A run of consecutive non-important activity labels (thinking and tool runs
/// that are not artifacts, not failed, not [AskLabel], and not the live label of
/// a running turn), gathered by [MessageBubble._rows] and shown behind a single
/// centered toggle. Two or more such labels in a row are worth hiding behind it;
/// one on its own is not, and `_rows` leaves a lone label where it is.
///
/// State is per-run and in-memory: a run is [ValueKey]ed on its first part's
/// index so a per-delta rebuild of the message keeps the same [_collapsed]
/// across the rebuilds the streamer triggers, but a reload or a thread switch
/// starts collapsed again, the way every fresh view does.
class ActivityGroup extends StatefulWidget {
  const ActivityGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  State<ActivityGroup> createState() => _ActivityGroupState();
}

class _ActivityGroupState extends State<ActivityGroup> {
  bool _collapsed = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SelectionContainer.disabled(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.center,
            child: TextButton.icon(
              onPressed: () => setState(() => _collapsed = !_collapsed),
              icon: Icon(_collapsed ? Icons.expand_more : Icons.expand_less, size: 16),
              label: Text(_collapsed ? "Expand activities" : "Collapse activities"),
              style: _labelStyle(theme.colorScheme.onSurfaceVariant, _labelText(theme)),
            ),
          ),
          if (!_collapsed) ...widget.children,
        ],
      ),
    );
  }
}

/// An `artifact` call, once it is history: a prominent card the user taps to
/// open the page the model rendered. Output the user came for rather than
/// background activity, so not a slim [ToolLabel]. The artifact's identity is
/// in the part, not the tool call, so this reads an [ArtifactPart].
class ArtifactLabel extends ConsumerWidget {
  const ArtifactLabel({
    super.key,
    required this.chatId,
    required this.artifactId,
    required this.entryFile,
    required this.title,
  });

  final String chatId;
  final String artifactId;
  final String entryFile;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return _OutputCard(
      kind: "Artifact",
      label: title.isEmpty ? "View artifact" : title,
      icon: Icons.insert_chart_outlined,
      action: Icons.open_in_new,
      background: scheme.primaryContainer,
      foreground: scheme.onPrimaryContainer,
      onTap: () => ref
          .read(linkOpenerProvider)
          .openArtifact(context, chatId, artifactId, entryFile: entryFile, title: title),
    );
  }
}

/// A `create_skill` call, once it is history: a card the user taps to review
/// and install the skill the model drafted. Breaks an activity run the way an
/// artifact does, for the same reason.
class SkillInstallLabel extends StatelessWidget {
  const SkillInstallLabel({
    super.key,
    required this.chatId,
    required this.installId,
    required this.title,
  });

  final String chatId;
  final String installId;
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _OutputCard(
      kind: "Skill",
      label: title.isEmpty ? "Install skill" : title,
      icon: Icons.extension,
      action: Icons.install_desktop,
      background: scheme.secondaryContainer,
      foreground: scheme.onSecondaryContainer,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              SkillInstallPreviewPage(chatId: chatId, installId: installId),
        ),
      ),
    );
  }
}

/// The card [ArtifactLabel] and [SkillInstallLabel] are drawn as.
class _OutputCard extends StatelessWidget {
  const _OutputCard({
    required this.kind,
    required this.label,
    required this.icon,
    required this.action,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final String kind;
  final String label;
  final IconData icon;
  final IconData action;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Material(
          color: background,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: foreground.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon, size: 20, color: foreground),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          kind,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: foreground.withValues(alpha: 0.75),
                            letterSpacing: 0.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: foreground,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(action, size: 18, color: foreground.withValues(alpha: 0.7)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label({
    required this.icon,
    required this.text,
    required this.onTap,
    this.isError = false,
    this.iconWidget,
  });

  final IconData icon;
  final String text;
  final VoidCallback onTap;
  final bool isError;

  /// Overrides [icon] where the caller has a widget rather than an icon — a
  /// running tool's spinner, for instance.
  final Widget? iconWidget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isError ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant;
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: onTap,
        style: _labelStyle(color, _labelText(theme)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: _labelIcon,
              child: iconWidget ?? Icon(icon, size: _labelIcon),
            ),
            const SizedBox(width: _labelGap),
            // One line: the label names what happened, the drawer says it.
            Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 16, color: color.withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }
}

/// The labels' type: the body size rather than Material's 12pt label tier,
/// which read as squeezed against a reply in Source Serif, but no weight and
/// the muted colour, so a label stays quieter than anything said.
TextStyle? _labelText(ThemeData theme) =>
    theme.textTheme.bodyMedium?.copyWith(fontSize: 13.5, height: 1.3);

const double _labelIcon = 16;
const double _labelGap = 10;
const double _labelPadX = 10;

/// The frameless, one-line button every label above a reply is drawn as.
ButtonStyle _labelStyle(Color color, TextStyle? text) => TextButton.styleFrom(
      foregroundColor: color,
      textStyle: text,
      padding: const EdgeInsets.symmetric(horizontal: _labelPadX, vertical: 7),
      minimumSize: const Size(0, 34),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    );

typedef ActivitySection = ({String? label, String? body, bool isError});

/// A message as it stands now, for a drawer left open while its turn runs.
/// [running] is the room's: a block or a call with no end yet is live only
/// while a turn is.
typedef LiveMessage = ({Message? message, String? shellOutput, bool running});

/// Message [id] of [view] as a drawer follows it.
LiveMessage liveMessageOf(ChatViewState view, String id) => (
      message: view.chat?.messages.where((m) => m.id == id).firstOrNull,
      shellOutput: view.shellOutput[id],
      running: view.isRunning,
    );

/// What an open drawer shows, re-read from the [LiveMessage] each time it
/// changes. A null [title] keeps the one it opened with.
typedef ActivityView = ({
  String? title,
  ActivityStatus? status,
  List<ActivitySection> sections,
  bool live,
});

/// Where a label's drawer reads its message from once it is open. The label
/// cannot be: it is rebuilt per delta, folded into a collapsed run when its
/// block closes, and gone when the list scrolls it away, all while the drawer
/// it opened is still up. Above each message on the chat page; absent, a
/// drawer shows what it was opened with and nothing more.
class ActivitySource extends InheritedWidget {
  const ActivitySource({super.key, required this.live, required super.child});

  final ProviderListenable<LiveMessage> live;

  static ProviderListenable<LiveMessage>? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ActivitySource>()?.live;

  // Read once, at the tap that opens a drawer, so nothing depends on it.
  @override
  bool updateShouldNotify(ActivitySource oldWidget) => false;
}

/// The drawer behind a label, opened at most of the screen. A modal route, so
/// the back key closes it; on a wide window as wide as a reading column, not
/// Material's 640. On the surface a dialog sits on, which is what it is drawn
/// after.
Future<T?> showActivityCard<T>(BuildContext context, WidgetBuilder builder) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      constraints: const BoxConstraints(maxWidth: 960),
      builder: builder,
    );

/// The drawer behind a label, for what a message recorded.
///
/// With [follow] it streams: what it shows is re-read from the message each
/// time the message changes, and while [ActivityView.live] it keeps to the
/// end of what is arriving until the reader scrolls back.
///
/// [below] is drawn under the sections and watched through the drawer's own
/// ref, so what it watches keeps the drawer following too.
Future<void> showActivitySheet(
  BuildContext context, {
  required String title,
  required List<ActivitySection> sections,
  IconData? icon,
  bool mono = false,
  String? command,
  ActivityStatus? status,
  ActivityView? Function(LiveMessage now, WidgetRef ref)? follow,
  Widget? Function(WidgetRef ref)? below,
}) {
  final source = follow == null ? null : ActivitySource.of(context);
  return showActivityCard<void>(
    context,
    (context) => _ActivitySheet(
      title: title,
      icon: icon,
      sections: sections,
      mono: mono,
      command: command,
      status: status,
      view: source == null || follow == null
          ? null
          : (ref) => follow(ref.watch(source), ref),
      below: below,
    ),
  );
}

class _ActivitySheet extends ConsumerWidget {
  const _ActivitySheet({
    required this.title,
    required this.icon,
    required this.sections,
    required this.mono,
    required this.command,
    required this.status,
    required this.view,
    this.below,
  });

  final String title;
  final IconData? icon;
  final List<ActivitySection> sections;
  final bool mono;
  final String? command;
  final ActivityStatus? status;
  final Widget? Function(WidgetRef ref)? below;

  /// What the drawer shows now, watched through the ref it is handed. Null
  /// where there is nothing to follow.
  final ActivityView? Function(WidgetRef ref)? view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = view?.call(ref);
    return ActivityCard(
      title: now?.title ?? title,
      icon: icon,
      command: command,
      status: now == null ? status : now.status,
      sections: now?.sections ?? sections,
      mono: mono,
      live: now?.live ?? false,
      below: below?.call(ref),
    );
  }
}

/// A status line under a card's title: "Running · pid 4001", "Exit code 1".
typedef ActivityStatus = ({String text, bool isError});

/// What a drawer draws, whoever is feeding it. Sections with nothing in them
/// are left out, so a tool that returned nothing does not show an empty
/// heading. [command] is set the way a `!` message is, under the title.
///
/// It opens at most of the screen and grows to the whole of it: a drawer
/// sized to a one-line output was a strip at the bottom of the window, and a
/// fraction of the height left empty below a long one is a fraction of the
/// output not read. While [live] it keeps to the end of what is arriving
/// until the reader scrolls back.
class ActivityCard extends StatefulWidget {
  const ActivityCard({
    super.key,
    required this.title,
    required this.sections,
    this.icon,
    this.command,
    this.status,
    this.actions = const [],
    this.mono = false,
    this.live = false,
    this.below,
  });

  final String title;
  final IconData? icon;
  final String? command;
  final ActivityStatus? status;

  /// Beside the close button: what can be done to the thing shown.
  final List<Widget> actions;

  final List<ActivitySection> sections;
  final bool mono;
  final bool live;
  final Widget? below;

  @override
  State<ActivityCard> createState() => _ActivityCardState();
}

class _ActivityCardState extends State<ActivityCard> {
  final _scroll = ScrollController();
  late final _follow = ScrollFollow(_scroll);

  /// How much of the screen the drawer takes before what is in it asks for
  /// more.
  static const _openAt = 0.6;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final extra = widget.below;
    final live = widget.live;
    final filled = widget.sections
        .where((s) => s.body != null && s.body!.trim().isNotEmpty)
        .toList();
    if (live) _follow.jumpIfFollowing();

    final muted = theme.colorScheme.onSurfaceVariant;
    final status = widget.status;
    final header = Row(
      children: [
        if (widget.icon != null) ...[
          Icon(widget.icon, size: 22, color: muted),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Text(
            widget.title,
            style: theme.textTheme.headlineSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (live)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: muted),
            ),
          ),
        ...widget.actions,
        IconButton(
          tooltip: "Close",
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );

    Widget body(ActivitySection section, {required bool last}) {
      final style = widget.mono
          ? codeBlockStyle(theme).copyWith(
              color: section.isError ? theme.colorScheme.error : null)
          : theme.textTheme.bodyMedium?.copyWith(
              color: section.isError ? theme.colorScheme.error : null,
              height: 1.5,
            );
      final caret = live && last && !section.isError;
      final text = caret
          ? Text.rich(
              TextSpan(text: section.body, children: [
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: StreamingCaret(
                    color: theme.colorScheme.primary,
                    height: style?.fontSize ?? 14,
                  ),
                ),
              ]),
              style: style,
            )
          // The newline output ends on would draw as a blank line under it.
          : Text(widget.mono ? section.body!.trimRight() : section.body!,
              style: style);
      if (!widget.mono) return text;
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: codeBlockDecoration(theme),
        child: text,
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) => ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight * _openAt),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 12, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              if (status != null)
                Text(
                  status.text,
                  style: theme.textTheme.labelMedium?.copyWith(
                      color: status.isError ? theme.colorScheme.error : muted),
                ),
              const SizedBox(height: 8),
              Flexible(
                child: NotificationListener<ScrollNotification>(
                  onNotification: _follow.onNotification,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.only(right: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectionArea(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (widget.command case final command?)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                                  child: ShellCommandText(command: command),
                                ),
                              for (final (i, section) in filled.indexed) ...[
                                if (section.label != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 16, bottom: 8),
                                    child: SelectionContainer.disabled(
                                      child: Text(
                                        section.label!,
                                        style: theme.textTheme.labelMedium?.copyWith(
                                          color: muted,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                                body(section,
                                    last: extra == null && i == filled.length - 1),
                              ],
                            ],
                          ),
                        ),
                        ?extra,
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "12 seconds", "2 minutes 5 seconds" — what a label reads after "Thought for".
String formatThinkingTime(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  if (seconds < 1) return "a moment";
  if (seconds < 60) return plural(seconds, "second");
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  final head = plural(minutes, "minute");
  return rest == 0 ? head : "$head ${plural(rest, "second")}";
}

/// "a moment ago", "5 minutes ago", "2 days ago" — how long ago something
/// happened. Coarse on purpose: it is read to decide whether carrying on still
/// makes sense, not to know exactly when.
String formatAge(Duration age) {
  if (age.inMinutes < 1) return "a moment ago";
  if (age.inHours < 1) return "${plural(age.inMinutes, "minute")} ago";
  if (age.inDays < 1) return "${plural(age.inHours, "hour")} ago";
  return "${plural(age.inDays, "day")} ago";
}

/// "23m left", "5h left", "3d left" — how long before a temporary chat expires.
/// Coarse like [formatAge]: the shortest TTL is 24 hours, so minute precision
/// is enough. "expiring" is the brief edge state before the sweep hides it.
String formatRemaining(Duration remaining) {
  if (remaining.inMinutes <= 0) return "expiring";
  if (remaining.inHours < 1) return "${plural(remaining.inMinutes, "minute")} left";
  if (remaining.inDays < 1) return "${plural(remaining.inHours, "hour")} left";
  return "${plural(remaining.inDays, "day")} left";
}

/// "1 chat", "3 chats". Public because three files past this one say it.
String plural(int count, String unit) => "$count $unit${count == 1 ? "" : "s"}";
