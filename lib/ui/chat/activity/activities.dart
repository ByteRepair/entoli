import "../../../domain/models.dart";
import "../tool_ui/tool_ui.dart";
import "activity.dart";
import "approval.dart";
import "instructions.dart";
import "output_cards.dart";
import "thinking.dart";

/// The kind of activity [part] is drawn as, or null for a part that is not
/// one — text, an error, a file, a command the user ran.
Activity? activityFor(MessagePart part) => switch (part) {
      ReasoningPart() => const ThinkingActivity(),
      ToolCallPart(:final toolCall) => toolUIFor(toolCall.name),
      ToolResultPart() => genericToolUI,
      InstructionsPart() => const InstructionsActivity(),
      ApprovalPart() => const ApprovalActivity(),
      ArtifactPart() => const ArtifactActivity(),
      SkillInstallPart() => const SkillInstallActivity(),
      _ => null,
    };
