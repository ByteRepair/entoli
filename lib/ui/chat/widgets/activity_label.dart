import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../fonts.dart";
import "../../skills/skill_install_preview.dart";
import "../../../domain/ask.dart";
import "../../../domain/file_tools.dart";
import "../../../domain/models.dart";
import "../../../domain/tool_arg.dart";
import "../../../providers.dart";

/// What the model did before it answered, on a line of its own above the
/// reply: thinking, and tool runs. Frameless, so it reads as a label until it
/// is tapped, which opens the detail in a drawer.
class ThinkingLabel extends StatelessWidget {
  const ThinkingLabel({super.key, required this.part, this.isLive = false});

  final ReasoningPart part;

  /// The model is writing this block right now.
  final bool isLive;

  String get _text {
    if (isLive) return "Thinking…";
    final ms = part.durationMs;
    // Neither streamed nor timed: an older conversation, or an aborted turn.
    return ms == null ? "View thinking" : "Thought for ${formatThinkingTime(ms)}";
  }

  @override
  Widget build(BuildContext context) {
    return _Label(
      icon: Icons.psychology_outlined,
      text: _text,
      onTap: () => showActivitySheet(
        context,
        title: "Thinking",
        sections: [(label: null, body: part.text, isError: false)],
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
    return _Label(
      icon: _failed ? Icons.error_outline : Icons.terminal,
      text: name == null ? verb : "$verb: $name",
      isError: _failed,
      // A running tool gets a spinner instead of a static icon, so the turn
      // shows it is busy even after the model has said something. The spinner
      // below the message handles the no-text-yet case, so this only shows
      // where that one doesn't.
      iconWidget: showSpinner
          ? SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      onTap: () => showActivitySheet(
        context,
        title: name ?? "Tool",
        mono: true,
        sections: [
          ..._runSections(call!, result),
          if (result != null && result!.violations.isNotEmpty)
            (
              label: "Sandbox",
              body: result!.violations.join("\n"),
              isError: true,
            ),
        ],
      ),
    );
  }
}

/// The drawer a tool run opens, whether it was drawn as a label or as a diff.
List<ActivitySection> _runSections(ToolCall call, ToolResult? result) => [
      (label: "Arguments", body: call.argumentsText ?? call.argumentsJson, isError: false),
      (label: "Output", body: result?.output, isError: false),
      (label: "Error", body: result?.exceptionInfo, isError: true),
    ];

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
        style: TextButton.styleFrom(
          foregroundColor: theme.colorScheme.onSurfaceVariant,
          textStyle: theme.textTheme.labelMedium,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.description_outlined, size: 15, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(title),
              ]),
              for (final line in removed)
                Text("- $line", style: TextStyle(fontFamily: monoFamily, color: red)),
              for (final line in added)
                Text("+ $line", style: TextStyle(fontFamily: monoFamily, color: green)),
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

/// A `task` call, once it is history: the sub-agent that ran and the text it
/// returned. Reads the agent name and prompt out of the call's arguments.
class TaskLabel extends StatelessWidget {
  const TaskLabel({super.key, required this.call, this.result});

  final ToolCall call;

  /// Null while the sub-agent is still running.
  final ToolResult? result;

  @override
  Widget build(BuildContext context) {
    final (agent, prompt) = _parse(call.argumentsJson);
    final failed = (result?.returnCode ?? 0) != 0;
    return _Label(
      icon: failed ? Icons.error_outline : Icons.account_tree_outlined,
      text: result == null
          ? "Running sub-agent @$agent"
          : "Sub-agent @$agent ${failed ? "failed" : "finished"}",
      isError: failed,
      onTap: () => showActivitySheet(
        context,
        title: "Sub-agent @$agent",
        sections: [
          (label: "Prompt", body: prompt, isError: false),
          (label: "Output", body: result?.output, isError: false),
          (label: "Error", body: result?.exceptionInfo, isError: true),
        ],
      ),
    );
  }

  (String, String) _parse(String? json) {
    final agent = stringArg(json, "agent") ?? "task";
    final prompt = stringArg(json, "prompt") ?? "";
    return (agent, prompt);
  }
}

/// A `websearch` call, once it is history. Reads the query out of the call's
/// arguments and shows the results behind the drawer.
class WebSearchLabel extends StatelessWidget {
  const WebSearchLabel({super.key, required this.call, this.result});

  final ToolCall call;
  final ToolResult? result;

  @override
  Widget build(BuildContext context) {
    final query = stringArg(call.argumentsJson, "query") ?? "";
    final failed = (result?.returnCode ?? 0) != 0;
    return _Label(
      icon: failed ? Icons.error_outline : Icons.travel_explore_outlined,
      text: result == null ? "Searching: $query" : "Searched: $query",
      isError: failed,
      onTap: () => showActivitySheet(
        context,
        title: "Web search",
        mono: true,
        sections: [
          (label: "Query", body: query, isError: false),
          (label: "Results", body: result?.output, isError: false),
          (label: "Error", body: result?.exceptionInfo, isError: true),
        ],
      ),
    );
  }
}

/// A `webfetch` call, once it is history. Reads the URL out of the call's
/// arguments and shows the fetched content behind the drawer.
class WebFetchLabel extends StatelessWidget {
  const WebFetchLabel({super.key, required this.call, this.result});

  final ToolCall call;
  final ToolResult? result;

  @override
  Widget build(BuildContext context) {
    final url = stringArg(call.argumentsJson, "url") ?? "";
    final failed = (result?.returnCode ?? 0) != 0;
    return _Label(
      icon: failed ? Icons.error_outline : Icons.language_outlined,
      text: result == null ? "Fetching: $url" : "Fetched: $url",
      isError: failed,
      onTap: () => showActivitySheet(
        context,
        title: "Web fetch",
        mono: true,
        sections: [
          (label: "URL", body: url, isError: false),
          (label: "Content", body: result?.output, isError: false),
          (label: "Error", body: result?.exceptionInfo, isError: true),
        ],
      ),
    );
  }
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
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.onSurfaceVariant,
                textStyle: (theme.textTheme.labelMedium ?? const TextStyle())
                    .copyWith(fontWeight: FontWeight.w600),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          if (!_collapsed) ...widget.children,
        ],
      ),
    );
  }
}

/// An `artifact` call, once it is history: a prominent card the user taps to
/// open the page the model rendered. Not a slim [ToolLabel] the way the
/// original was: an artifact is output the user came for, not background
/// activity, so it is drawn as the one thing in the conversation worth
/// reaching for. The artifact's identity is in the part, not the tool call,
/// so this reads an [ArtifactPart] rather than a [ToolCall].
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = title.isEmpty ? "View artifact" : title;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Material(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => ref
                .read(linkOpenerProvider)
                .openArtifact(context, chatId, artifactId, entryFile: entryFile, title: title),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: scheme.onPrimaryContainer.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.insert_chart_outlined,
                      size: 20,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          "Artifact",
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onPrimaryContainer.withValues(alpha: 0.75),
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
                            color: scheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.open_in_new,
                    size: 18,
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A `create_skill` call, once it is history: a prominent card the user taps
/// to review and install the skill the model drafted. Mirrors [ArtifactLabel]:
/// a skill offered for install is output the user came for, not background
/// activity, so it breaks an activity run the way an artifact does.
class SkillInstallLabel extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = title.isEmpty ? "Install skill" : title;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Material(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _openPreview(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: scheme.onSecondaryContainer.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.extension,
                      size: 20,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          "Skill",
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSecondaryContainer
                                .withValues(alpha: 0.75),
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
                            color: scheme.onSecondaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.install_desktop,
                    size: 18,
                    color: scheme.onSecondaryContainer.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openPreview(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SkillInstallPreviewPage(
          chatId: chatId,
          installId: installId,
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
      child: TextButton.icon(
        onPressed: onTap,
        icon: iconWidget ?? Icon(icon, size: 15),
        label: Text(text),
        style: TextButton.styleFrom(
          foregroundColor: color,
          textStyle: theme.textTheme.labelMedium,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

typedef ActivitySection = ({String? label, String? body, bool isError});

/// The drawer behind a label. Sections with nothing in them are left out, so
/// a tool that returned nothing does not show an empty heading.
///
/// It grows to what is in it, up to the whole screen: a tool's output is as
/// long as it is, and a fraction of the height left empty below it is a
/// fraction of the output not read. A modal route, so the back key closes it.
Future<void> showActivitySheet(
  BuildContext context, {
  required String title,
  required List<ActivitySection> sections,
  bool mono = false,
}) {
  final filled = sections.where((s) => s.body != null && s.body!.trim().isNotEmpty).toList();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) {
      final theme = Theme.of(context);
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final section in filled) ...[
                      if (section.label != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 2),
                          child: Text(
                            section.label!,
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      SelectableText(
                        section.body!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFamily: mono ? monoFamily : null,
                          color: section.isError ? theme.colorScheme.error : null,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
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
