import "../../../domain/models.dart";
import "../tool_ui/tools.dart";
import "activity.dart";
import "approval.dart";
import "instructions.dart";
import "output_cards.dart";
import "thinking.dart";

/// Every kind of activity, by the part it draws.
class ChatActivities implements ActivityCatalog {
  const ChatActivities();

  @override
  Activity? of(MessagePart part) => switch (part) {
    ReasoningPart() => const ThinkingActivity(),
    ToolCallPart(:final toolCall) => toolUIFor(toolCall.name),
    ToolResultPart() => genericToolUI,
    InstructionsPart() => const InstructionsActivity(),
    ApprovalPart() => const ApprovalActivity(),
    ArtifactPart() => const ArtifactActivity(),
    SkillInstallPart() => const SkillInstallActivity(),
    _ => null,
  };
}
