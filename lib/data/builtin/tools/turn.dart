import "package:fs_shim/fs.dart";

import "../../../domain/agent_backend.dart";
import "../../../domain/agent_browser.dart";
import "../../../domain/ask.dart";
import "../../../domain/file_tools.dart";
import "../../../domain/permission.dart" show ApproveMode;
import "../../../domain/shell.dart";
import "../../../domain/trigger_manager.dart" show TriggerRegistry;
import "../../../domain/web_search.dart";
import "../approval_gate.dart";
import "../background_jobs.dart";
import "../builtin_options.dart";
import "../llm/llm_client.dart";
import "../memory/store.dart";
import "../../../domain/app_settings.dart" show SettingsEditor;

/// What a running tool may reach of the turn it runs in: the workspaces, the
/// shell, the gate, the user, and whichever of the optional collaborators
/// this turn was handed. A collaborator a turn has none of is null, and the
/// tool that needs it is not offered — [AgentTool.offered] reads the same
/// fact off the offer — so a tool reads its own with `!`.
///
/// `BuiltinAgent` is the one implementation: a turn is an agent running.
abstract interface class Turn {
  /// The filesystem the file tools operate on: `fileSystemIo` on a disk,
  /// IndexedDB in a browser, so the file tools work everywhere.
  FileSystem get fs;

  /// The chat's own directory, where the shell starts.
  String get workspace;

  /// The project's workspace: shared between the project's chats where it is
  /// shared, the chat's own where it is not.
  String get projectWorkspace;

  /// A file-tool path, resolved through the workspaces, the guest root and
  /// the shell's home.
  String resolvePath(String path);

  Shell get shell;

  /// The project's own command variables, layered over the app's.
  Map<String, String> get environment;

  /// The project, for a per-project rootfs; null for the default and users'.
  String? get project;

  /// What a command may read and must not write.
  List<String> get readOnlyDirs;

  BuiltinOptions get options;

  /// The app's own data directory, which no grant may reach. Null where a
  /// test does not exercise the refusal.
  String? get dataDir;

  /// The files the model has read, as they stood when it read them: what
  /// `write` and `edit` check an existing file against.
  Map<String, FileStamp> get readFiles;

  /// The rules and the approval mode, between a call and its run.
  ApprovalGate get gate;

  /// Puts questions to the user; one answer per question, null where they
  /// answered nothing.
  Future<List<String?>> Function(AskRequest request) get answer;

  /// The chat's `resources/`, read-only to the agent; null on a sub-agent.
  String? get attachmentsDir;

  bool get seesImages;
  bool get seesPdfs;

  /// How a `read` pulls in the instructions above a file.
  MemorySettings get memory;

  /// AGENTS.md paths already in front of the model; a read adds what it
  /// pulls in, so the same file is never injected twice.
  Set<String> get loadedInstructions;

  /// Marks an instruction file first reached by this conversation; null
  /// treats every finding as new.
  bool Function(String path)? get claimInstruction;

  MemoryStore? get memoryStore;

  /// What a saved memory is stamped with: the chat that wrote it.
  String? get memoryChat;

  WebSearch? get webSearch;

  /// This chat's tab in the agent's browser.
  BrowserTab? get browser;

  /// The mode the browser's navigation and actions are gated by, in place
  /// of the turn's own.
  ApproveMode get browserApprove;

  Future<String> Function(String path, String entryFile, {String? artifactId})?
      get saveArtifact;
  Future<List<LlmAttachment>> Function(String prompt)? get generateImage;
  Future<({String installId, String name})> Function(String path, String? name)?
      get packageSkill;
  TriggerRegistry? get registerTrigger;
  ChatJobs? get backgroundJobs;
  SettingsEditor? get editSettings;
  SubAgents? get subAgents;

  /// Whether the turn was stopped.
  bool get cancelled;

  /// [wait], or null where the turn is stopped first.
  Future<T?> untilStopped<T>(Future<T> wait);

  /// Stop the loop after the batch this call is in, without asking the model
  /// again.
  void endTurn();

  /// Whether there is somewhere to keep what a tool shows: a sub-agent's
  /// images are dropped.
  bool get savesResources;

  /// [image] saved under the chat's `resources/`, as the event that puts it
  /// on the reply — and on the call's result, for the model.
  Future<ImageEvent> saved(LlmAttachment image);

  /// [run]'s result, with its output reported as it prints and the run
  /// killed by a stop.
  Future<ShellResult> track(LlmToolCall call, ShellRun run);
}

/// What a turn asks of its sub-agents: run one to the end for a `task` call,
/// and stop every one still running. The loop that spawns them implements
/// it, above the tools; a tool only holds this.
abstract interface class SubAgents {
  /// Run [agentName] on [prompt] headless; its final text is the result.
  Future<ShellResult> run(String agentName, String prompt, {String? callId});

  /// Stop every sub-agent still running.
  Future<void> cancel();
}
