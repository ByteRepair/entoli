import "../../../domain/agent_backend.dart";
import "../../../domain/artifact.dart";
import "../../../domain/shell.dart";
import "../approval_gate.dart";
import "../llm/llm_client.dart";
import "../templates.dart" show systemProse;
import "agent_tool.dart";
import "turn.dart";

/// Publish an HTML page the user can view in the app. The model writes the
/// files to its workspace with `write`/`edit`, then calls this tool with the
/// path to the entry point HTML file. The harness copies the file's parent
/// directory into the chat's `artifacts/` and opens the entry file in the
/// viewer. A path the workspaces hold runs without asking; one that reaches
/// past them is offered to the user first, since publishing is what makes the
/// file's bytes part of the chat. Not offered to a sub-agent, which has no
/// viewer to open what it made.
class ArtifactTool extends AgentTool {
  ArtifactTool(super.offer);

  @override
  ToolGroup get group => ToolGroup.artifacts;

  @override
  String get name => artifactToolName;

  @override
  bool get offered => offer.caps.artifact;

  @override
  String get runningLabel => "Publishing the artifact";

  @override
  String get fragment => "`artifact` to publish an HTML page the user can view";

  @override
  String get section => systemProse("artifacts");

  @override
  String get description => "Publish an HTML page the user can view in the "
      "app. Write the HTML and supporting files to your workspace with "
      "`write`/`edit`, then call this tool with the path to the entry point "
      "HTML file. The harness copies the file's directory and opens it in the "
      "app's viewer. The viewer has no network, so inline or include "
      "everything the page needs. To update an artifact, edit the files and "
      "call this tool again with the same `artifact_id`.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "Workspace-relative path to the entry point HTML "
                "file (e.g. \"report/index.html\" or \"chart.html\"). Prefix "
                "with `project:` to publish from the project workspace.",
          },
          "title": {
            "type": "string",
            "description": "A short title for the artifact card.",
          },
          "artifact_id": {
            "type": "string",
            "description": "The id returned by a previous `artifact` call. "
                "Pass this to update an existing artifact in place rather "
                "than creating a new one.",
          },
        },
        "required": ["path"],
      };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final parsed = artifactArgsFrom(call.argumentsJson);
    if (parsed == null) {
      yield* toolRejected(call,
          'The $artifactToolName tool takes {"path": "..."}; that argument was missing.');
      return;
    }
    final path = turn.resolvePath(parsed.path);
    yield toolCalled(call, parsed.title.isEmpty ? parsed.path : parsed.title);
    String? artifactId;
    final outcome = GateOutcome();
    yield* turn.gate.path(call, path, artifactToolName, () async {
      artifactId = await turn.saveArtifact!(parsed.path, parsed.entryFile,
          artifactId: parsed.artifactId);
      return const ShellResult(returnCode: 0, output: "");
    }, outcome);
    final id = artifactId;
    if (outcome.result!.returnCode != 0 || id == null) {
      yield ToolResultEvent(outcome.resultOf(call));
      return;
    }
    yield ArtifactEvent(artifactId: id, entryFile: parsed.entryFile, title: parsed.title);
    final label = parsed.title.isEmpty ? parsed.path : "'${parsed.title}'";
    // One output, so the model is told how to update it on a reload too — the
    // instructions used to be said to the model alone and were lost with the
    // session.
    outcome.result = ShellResult(
        returnCode: 0,
        output: "Artifact $label published. The user can view it in the app. "
            "It is saved with the chat. To update it, edit the files and call "
            "artifact again with artifact_id: \"$id\".");
    yield ToolResultEvent(outcome.resultOf(call));
  }
}
