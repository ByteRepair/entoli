// The directory grant tools. The model asks for write access to a directory
// outside the workspaces with `add_directory`, the user answers on the
// approval banner: the directory joins the turn's runtime grant through
// [ApprovalGate.grant], and an "always" answer lands in the named tier's
// `writableDirs` — [ChatRepository.respondApproval] persists
// `ToolApproval.deniedDirs` there, so the tool carries its directory in that
// field. Nothing persists or is granted without the banner: the description
// is the only thing that tells the model the tool exists.

import "dart:io";

import "../../../domain/agent_backend.dart";
import "../../../domain/models.dart";
import "../../../domain/permission.dart";
import "../../../domain/shell.dart";
import "../../../domain/file_tools.dart" show outsideWorkspaces;
import "../../../domain/tool_arg.dart";
import "../llm/llm_client.dart";
import "agent_tool.dart";
import "turn.dart";
import "../tool_outcome.dart";

/// The directory grant request. The banner is the whole grant: the model
/// names a directory, the user answers on the ordinary approval banner less
/// its plain Allow, and the rest of this turn is covered by the gate's grant.
/// It rides `ask` — a banner somebody answers — and only a top-level turn is
/// its own chat's to cover.
///
/// Three shapes refuse before any banner: the app's own data tree — the
/// data directory, anything beneath it, or anything containing it, which
/// would make the app's settings, secrets and chats writable from inside its
/// own permit — a path that names nothing, and a file where a directory was
/// asked for.
class AddDirectoryTool extends AgentTool {
  AddDirectoryTool(super.offer);

  @override
  ToolGroup get group => ToolGroup.directories;

  @override
  String get name => addDirectoryName;

  @override
  bool get offered => offer.caps.ask && !offer.oneShot;

  @override
  String get description => "Request persistent write access to a directory "
      "outside the workspace, when the task needs write access there "
      "repeatedly. One approval covers the directory, so writes in it "
      "afterwards run without asking. Call this when the user has indicated "
      "that the work should be done in a specific folder outside of the chat "
      "or project workspaces. On a denial, carry on with the task; writes in "
      "that folder keep raising the ordinary per-write approval the user "
      "answers one at a time, and do not call this again this turn.";

  @override
  Map<String, dynamic> get schema => const {
        "type": "object",
        "properties": {
          "path": {
            "type": "string",
            "description": "The directory to request write access to: an "
                "absolute path, or one starting with ~ for the machine's "
                "home. A directory, not a file.",
          },
        },
        "required": ["path"],
      };

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    final path = stringArg(call.argumentsJson, "path");
    if (path == null) {
      yield* toolRejected(
          call,
          'The $addDirectoryName tool takes {"path": "..."}; that argument '
          "was missing.");
      return;
    }
    yield toolCalled(call, path);
    final resolved = turn.resolvePath(path);
    final type = FileSystemEntity.typeSync(resolved);
    if (type == FileSystemEntityType.notFound) {
      yield toolFailed(call, "Directory not found: $resolved. "
          "Create it first, then ask again.");
      return;
    }
    if (type != FileSystemEntityType.directory) {
      yield toolFailed(call, "$resolved is not a directory. The grant covers a "
          "directory and everything under it; ask again with the directory "
          "the work belongs in.");
      return;
    }
    if (!outsideWorkspaces(resolved, turn.workspace, turn.projectWorkspace)) {
      yield toolOk(call, "$resolved is inside the workspaces, and writes there "
          "are already allowed. Nothing was granted.");
      return;
    }
    // The tree either way — beneath it is the app's own data, containing it
    // hands those writes to the sandbox — answered after the workspaces,
    // whose directories live beneath this tree and need no grant. A symlink
    // is chased to where it points, so one aliasing the data dir is the data
    // dir.
    final dataDir = turn.dataDir;
    if (dataDir != null && pathsOverlap(resolved, dataDir)) {
      yield toolFailed(call, "$resolved holds this app's own data, or lies "
          "inside it, which is not grantable. Choose a directory outside it.");
      return;
    }
    // The banner names the resolved path — the real directory is what a yes
    // agrees to — and carries it in `deniedDirs`, the field the repository's
    // approval answer already persists on.
    final approval = ToolApproval(
      id: call.id,
      toolName: addDirectoryName,
      argumentsJson: call.argumentsJson,
      argumentsText: resolved,
      deniedDirs: [resolved],
    );
    yield ApprovalRequestEvent(approval);
    final answer = await turn.gate.approve(approval);
    if (!answer.isAllow) {
      yield ToolResultEvent(toolRan(
          call,
          ShellResult.failed(
              "Denied. Write access to $resolved was not granted; carry on "
              "with the task — writes in that folder keep raising the "
              "ordinary per-write approval. Do not call $addDirectoryName "
              "again this turn."),
          decision: (
            source: PermissionSource.human,
            tiers: const [PermissionTier.once],
            decided: PermissionDecision.deny,
          )));
      return;
    }
    turn.gate.grant([resolved]);
    final (tiers, wording) = switch (answer) {
      ApprovalResponse.alwaysAllowChat => (
          const [PermissionTier.chat],
          "Allowed in this chat: the grant is saved with the conversation, so "
              "writes in $resolved run without asking here.",
        ),
      ApprovalResponse.alwaysAllowProject => (
          const [PermissionTier.project],
          "Allowed for this project: the grant is saved with the project, so "
              "writes in $resolved run without asking in the project's chats.",
        ),
      _ => (
          const <PermissionTier>[],
          "Allowed for the rest of this turn: writes in $resolved run without "
              "asking until the turn ends.",
        ),
    };
    yield ToolResultEvent(toolRan(
        call, ShellResult(returnCode: 0, output: wording),
        decision: (
          source: PermissionSource.human,
          tiers: tiers,
          decided: PermissionDecision.allow,
        )));
  }
}

/// The turn's writable set, named. The workspaces stand first, every write
/// in them being free; what `add_directory` granted, standing or mid-turn,
/// after them — anything the workspaces already hold is left out of that
/// half, for being no grant at all; and `~` is spelled out, since the tools
/// and commands take that shorthand and the grants are recorded absolute.
class WritableDirectoriesTool extends AgentTool {
  WritableDirectoriesTool(super.offer);

  @override
  ToolGroup get group => ToolGroup.directories;

  @override
  String get name => writableDirectoriesName;

  @override
  String get description => "List the directories outside the workspaces "
      "that this chat or project has been granted write access to, plus the "
      "workspaces themselves.";

  @override
  Map<String, dynamic> get schema =>
      const {"type": "object", "properties": {}};

  @override
  Stream<AgentEvent> run(LlmToolCall call, Turn turn) async* {
    yield toolCalled(call);
    final dirs = [
      for (final dir in (await turn.gate.permissions()).writableDirs.toSet())
        if (outsideWorkspaces(dir, turn.workspace, turn.projectWorkspace))
          dir,
    ]..sort();
    final home = turn.shell.homeFor(turn.projectWorkspace);
    final lines = [
      "Workspace: ${turn.workspace}",
      "Project workspace: ${turn.projectWorkspace}",
      if (dirs.isEmpty)
        "No directories beside the workspaces have been granted write access."
      else ...[
        "Also writable, granted beside the workspaces:",
        for (final dir in dirs) "- $dir",
      ],
      if (home != null) "~ is $home.",
    ];
    yield toolOk(call, lines.join("\n"));
  }
}
