import "../../../domain/ask.dart";
import "../../settings/spec.dart" show SettingReader;
import "../activity.dart";
import "tool_run.dart";

/// A question to the user, once it is history: the question on a label, the
/// answers behind it. Voice mode says nothing of it — the panel is where a
/// question belongs, not a line above it. Named `ask_user` but with nothing
/// askable in it, the model got the shape wrong and was told so, which is an
/// ordinary failed tool run.
final class AskActivity extends ToolActivity {
  const AskActivity();

  @override
  String get tool => askToolName;

  @override
  String? get spoken => null;

  @override
  bool important(Run run) => true;

  @override
  ActivityNode node(SettingReader reader, Run run) {
    final questions = askQuestionsFrom(run.call?.argumentsJson);
    if (questions.isEmpty) return super.node(reader, run);
    return LabelNode(
      this,
      run,
      glyph: TranscriptGlyph.question,
      text: questions.length == 1
          ? questions.single.question
          : "Asked ${questions.length} questions",
    );
  }

  @override
  ActivityDetail? detail(SettingReader reader, Run run) {
    final questions = askQuestionsFrom(run.call?.argumentsJson);
    if (questions.isEmpty) return super.detail(reader, run);
    final answers = askAnswersFrom(run.result?.output);
    return ActivityDetail(
      title: "Asked the user",
      glyph: TranscriptGlyph.question,
      sections: [
        for (var i = 0; i < questions.length; i++)
          DetailSection(
            label: questions[i].question,
            body: answers.elementAtOrNull(i) ?? "Not answered",
          ),
      ],
    );
  }
}
