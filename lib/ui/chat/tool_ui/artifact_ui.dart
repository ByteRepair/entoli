import "../../../domain/artifact.dart";
import "tool_ui.dart";

class ArtifactUI extends ToolUI {
  const ArtifactUI();

  @override
  String get tool => artifactToolName;

  @override
  String get spoken => "Made an artifact";
}
