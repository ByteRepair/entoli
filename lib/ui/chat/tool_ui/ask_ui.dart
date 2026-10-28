import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../../domain/ask.dart";
import "../activity/activity.dart";
import "../activity/label.dart";
import "../activity/tool_run.dart" show toolRunView;
import "tool_ui.dart";

/// A question to the user: the question on a label, the answers behind the
/// drawer. Voice mode says nothing of it — the panel below is where a
/// question belongs, not a line above it.
class AskUI extends ToolUI {
  const AskUI();

  @override
  String get tool => askToolName;

  @override
  String? get spoken => null;

  @override
  bool important(Run run) => true;

  /// The questions and what was answered. Named `ask_user` but with nothing
  /// askable in it, the model got the shape wrong and was told so, which is
  /// an ordinary failed tool run and carries the reason a question would drop.
  @override
  RunView view(WidgetRef ref, Run run) {
    final questions = askQuestionsFrom(run.call?.argumentsJson);
    if (questions.isEmpty) return toolRunView(run);
    final answers = askAnswersFrom(run.result?.output);
    return RunView(
      icon: Icons.help_outline,
      label: questions.length == 1
          ? questions.single.question
          : "Asked ${questions.length} questions",
      drawer: (_) => RunDrawer(
        title: "Asked the user",
        sections: [
          for (var i = 0; i < questions.length; i++)
            (
              label: questions[i].question,
              body: answers.elementAtOrNull(i) ?? "Not answered",
              isError: false,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(Run run) => _AskLabel(activity: this, run: run);
}

/// A question the model put to the user, once it is history: the panel that
/// asked it is gone by then, so this reads the question back out of the call
/// and the answer out of the result that closed it. Parsed once and kept,
/// since every visible message is rebuilt on every streamed delta and the
/// JSON behind an asked question never changes.
class _AskLabel extends StatefulWidget {
  const _AskLabel({required this.activity, required this.run});

  final AskUI activity;
  final Run run;

  @override
  State<_AskLabel> createState() => _AskLabelState();
}

class _AskLabelState extends State<_AskLabel> {
  late List<AskQuestion> _questions;

  @override
  void initState() {
    super.initState();
    _questions = askQuestionsFrom(widget.run.call?.argumentsJson);
  }

  @override
  void didUpdateWidget(_AskLabel old) {
    super.didUpdateWidget(old);
    if (old.run.call?.argumentsJson != widget.run.call?.argumentsJson) {
      _questions = askQuestionsFrom(widget.run.call?.argumentsJson);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_questions.isEmpty) return RunLabel(activity: widget.activity, run: widget.run);
    return ActivityLabel(
      icon: Icons.help_outline,
      text: _questions.length == 1
          ? _questions.single.question
          : "Asked ${_questions.length} questions",
      onTap: () => widget.activity.open(context, widget.run),
    );
  }
}
