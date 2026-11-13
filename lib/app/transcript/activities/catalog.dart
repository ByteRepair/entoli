import "../../../domain/models.dart";
import "../../../domain/plan.dart";
import "../activity.dart";
import "ask.dart";
import "command.dart";
import "file.dart";
import "plan.dart";
import "records.dart";
import "task.dart";
import "thinking.dart";
import "todo.dart";
import "tool_run.dart";
import "web.dart";

/// Every tool that shows anything of its own.
const toolActivities = <ToolActivity>[
  BashActivity(),
  ReadActivity(),
  WriteActivity(),
  EditActivity(),
  WebSearchActivity(),
  WebFetchActivity(),
  TaskActivity(),
  AskActivity(),
  ArtifactToolActivity(),
  QuietPlanActivity(planAddToolName),
  QuietPlanActivity(planNextToolName),
  QuietPlanActivity(planDoneToolName),
  PresentPlanActivity(),
  TodoActivity(),
  AddDirectoryActivity(),
];

final _byName = {for (final tool in toolActivities) tool.tool: tool};

/// A tool run no tool claims: a result whose call is gone.
const genericToolActivity = GenericToolActivity("");

/// How the conversation shows a call of [tool].
ToolActivity toolActivityFor(String tool) =>
    _byName[tool] ?? GenericToolActivity(tool);

/// Every kind of activity, by the part it is.
class TranscriptActivities implements ActivityCatalog {
  const TranscriptActivities();

  @override
  Activity? of(MessagePart part) => switch (part) {
    ReasoningPart() => const ThinkingActivity(),
    ToolCallPart(:final toolCall) => toolActivityFor(toolCall.name),
    ToolResultPart() => genericToolActivity,
    InstructionsPart() => const InstructionsActivity(),
    ApprovalPart() => const ApprovalActivity(),
    ArtifactPart() => const ArtifactActivity(),
    SkillInstallPart() => const SkillInstallActivity(),
    _ => null,
  };
}
