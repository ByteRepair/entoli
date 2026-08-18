import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../fonts.dart";
import "../../../domain/ask.dart";
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
  const ToolLabel({super.key, this.call, this.result})
      : assert(call != null || result != null);

  final ToolCall? call;

  /// Null while the tool is still running.
  final ToolResult? result;

  bool get _failed => (result?.returnCode ?? 0) != 0;

  @override
  Widget build(BuildContext context) {
    final name = call?.name;
    final verb = result == null ? "Using tool" : "Used tool";
    final arguments = call?.argumentsText ?? call?.argumentsJson;
    return _Label(
      icon: _failed ? Icons.error_outline : Icons.terminal,
      text: name == null ? verb : "$verb: $name",
      isError: _failed,
      onTap: () => showActivitySheet(
        context,
        title: name ?? "Tool",
        mono: true,
        sections: [
          (label: "Arguments", body: arguments, isError: false),
          (label: "Output", body: result?.output, isError: false),
          (label: "Error", body: result?.exceptionInfo, isError: true),
        ],
      ),
    );
  }
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

class _Label extends StatelessWidget {
  const _Label({
    required this.icon,
    required this.text,
    required this.onTap,
    this.isError = false,
  });

  final IconData icon;
  final String text;
  final VoidCallback onTap;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isError ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant;
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 15),
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
