import "agent_tool.dart";
import "artifact_tool.dart";
import "ask_tool.dart";
import "bash_tool.dart";
import "browser_tools.dart";
import "customization_tools.dart";
import "directory_tools.dart";
import "file_tools.dart";
import "image_tool.dart";
import "memory_tools.dart";
import "participants_tool.dart";
import "plan_tools.dart";
import "skill_create_tool.dart";
import "skill_tool.dart";
import "task_tool.dart";
import "trigger_tool.dart";
import "websearch_tool.dart";

/// Every tool there is, built over [offer]. The order is the order the model
/// is handed them and the order the prompt names them in — and so part of
/// the prefix the warm-up caches, which is why there is one list.
List<AgentTool> agentTools(ToolOffer offer) => [
      ReadTool(offer),
      WriteTool(offer),
      EditTool(offer),
      BashTool(offer),
      ReadOnlyBashTool(offer),
      AskTool(offer),
      TaskTool(offer),
      WebSearchTool(offer),
      WebFetchTool(offer),
      SkillTool(offer),
      ListParticipantsTool(offer),
      EndTurnTool(offer),
      ArtifactTool(offer),
      PlanAddTool(offer),
      PlanNextTool(offer),
      PlanDoneTool(offer),
      PresentPlanTool(offer),
      CreateSkillTool(offer),
      TriggerSetTool(offer),
      TriggerRemoveTool(offer),
      TriggerListTool(offer),
      SetProfileTool(offer),
      SetToneTool(offer),
      MemorySaveTool(offer),
      MemorySearchTool(offer),
      MemoryUpdateTool(offer),
      MemoryDeleteTool(offer),
      AddDirectoryTool(offer),
      WritableDirectoriesTool(offer),
      ImageGenerationTool(offer),
      BrowserGotoTool(offer),
      BrowserSearchTool(offer),
      BrowserClickTool(offer),
      BrowserTypeTool(offer),
      BrowserPressTool(offer),
      BrowserDragTool(offer),
      BrowserScrollTool(offer),
      BrowserBackTool(offer),
      BrowserPageTextTool(offer),
      BrowserScreenshotTool(offer),
      BrowserCredentialsPromptTool(offer),
      BrowserCredentialsHideTool(offer),
      BrowserUploadTool(offer),
      AttachmentSaveTool(offer),
    ];

/// The tools [offer] holds: what the model is handed, what the prompt
/// names, and the only ones a call reaches. The agent picks among the ones
/// it may be granted; where it picked two of one name, the first wins.
List<AgentTool> offeredTools(ToolOffer offer) {
  final names = <String>{};
  return [
    for (final tool in agentTools(offer))
      if (tool.offered &&
          (tool.group == null ||
              offer.agent.offers(tool.id, byDefault: tool.onByDefault)) &&
          names.add(tool.name))
        tool,
  ];
}
