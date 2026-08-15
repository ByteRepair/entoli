import "package:flutter/material.dart";

import "../../../domain/ask.dart";
import "../../../domain/models.dart";

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
    showDragHandle: true,
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
          child: Padding(
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
                              fontFamily: mono ? "monospace" : null,
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
          ),
        ),
      );
    },
  );
}

/// "12 seconds", "2 minutes 5 seconds" — what a label reads after "Thought for".
String formatThinkingTime(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  if (seconds < 1) return "a moment";
  if (seconds < 60) return _plural(seconds, "second");
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  final head = _plural(minutes, "minute");
  return rest == 0 ? head : "$head ${_plural(rest, "second")}";
}

String _plural(int count, String unit) => "$count $unit${count == 1 ? "" : "s"}";
