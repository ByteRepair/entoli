import "../../domain/artifact.dart";
import "llm/llm_client.dart";

/// Publish an HTML page the user can view in the app. The model writes the
/// files to its workspace with `write`/`edit`, then calls this tool with the
/// path to the entry point HTML file. The harness copies the file's parent
/// directory into the artifact and opens the entry file in the viewer.
const artifactTool = LlmTool(
  name: artifactToolName,
  description: "Publish an HTML page the user can view in the app. Write the "
      "HTML and supporting files to your workspace with `write`/`edit`, then "
      "call this tool with the path to the entry point HTML file. The harness "
      "copies the file's directory and opens it in the app's viewer. The viewer "
      "has no network, so inline or include everything the page needs. To "
      "update an artifact, edit the files and call this tool again with the "
      "same `artifact_id`.",
  schema: {
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "Workspace-relative path to the entry point HTML file "
            "(e.g. \"report/index.html\" or \"chart.html\"). Prefix with "
            "`project:` to publish from the project workspace.",
      },
      "title": {
        "type": "string",
        "description": "A short title for the artifact card.",
      },
      "artifact_id": {
        "type": "string",
        "description": "The id returned by a previous `artifact` call. Pass "
            "this to update an existing artifact in place rather than creating "
            "a new one.",
      },
    },
    "required": ["path"],
  },
);