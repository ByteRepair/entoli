import "dart:async";

import "package:fs_shim/fs.dart";
import "package:flutter/foundation.dart" show visibleForTesting;
import "package:uuid/uuid.dart";

import "../../domain/agent_backend.dart";
import "../../domain/artifact.dart";
import "../../domain/ask.dart";
import "../../domain/command_grants.dart";
import "../../domain/date_words.dart" show describeFire;
import "../../domain/file_tools.dart";
import "../../domain/models.dart";
import "../../domain/permission.dart";
import "../../domain/plan.dart";
import "../../domain/profile.dart";
import "../../domain/prompt_library.dart";
import "../../domain/safe_command.dart" show SegmentReach;
import "../../domain/shell.dart";
import "../../domain/shell_command_analysis.dart";
import "../../domain/tone.dart";
import "../../domain/tool_arg.dart";
import "../../domain/turn_recorder.dart";
import "../../domain/web_search.dart";
import "ask_tool.dart";
import "artifact_tool.dart";
import "file_tools.dart" as file_tool_defs;
import "llm/llm_client.dart";
import "llm/rate_limit_gate.dart";
import "../prompts/skill_import.dart" show SkillImportException;
import "skill_create_tool.dart";
import "skill_tool.dart";
import "sub_agent.dart";
import "task_tool.dart";
import "trigger_tool.dart";
import "../../domain/trigger.dart";
import "../../domain/trigger_manager.dart" show TriggerRegistry;
import "projection.dart";
import "templates.dart";
import "memory/instructions.dart";
import "memory/store.dart";
import "memory_tools.dart";
import "plan_tools.dart";
import "websearch_tool.dart";

/// What the spinner says while the model reads the prompt.
///
/// A percentage rather than a count of tokens, which means nothing to anyone,
/// and nothing at all where the server reported a total of zero. `cache` is left
/// out deliberately: it is why the bar starts at 80% on a second turn, and
/// explaining that is not worth a row that has to stay one line.
String readingPrompt(LlmPromptProgress progress) {
  final fraction = progress.fraction;
  return fraction == null
      ? "Reading the prompt"
      : "Reading the prompt · ${(fraction * 100).round()}%";
}

/// What the spinner says while a tool runs, or null for the ones that finish
/// too fast to be worth naming — a file read is over before a frame is drawn,
/// and a label that flashes is worse than none.
String? runningTool(String name) => switch (name) {
      bashToolName => "Running a command",
      websearchToolName => "Searching the web",
      webfetchToolName => "Fetching a page",
      taskToolName => "Working on a sub-task",
      triggerSetName => "Setting a trigger",
      artifactToolName => "Publishing the artifact",
      presentPlanToolName => "Presenting the plan",
      _ => null,
    };

/// Named beside the tool the way every other tool's is, so that matching on it
/// is compiler-linked to the name the model is actually told.
const bashToolName = "bash";

/// The only tool for doing anything to the machine. Everything else — reading
/// a file, editing it, running the tests — is a command.
const _bashCommonArgs = {
  "command": {"type": "string", "description": "The bash command to execute"},
  "timeout": {
    "type": "integer",
    "description":
        "How long the command may run, in milliseconds. Set this to give a "
        "command a different deadline than the default 60000; values above "
        "180000 (3 minutes) are capped to it.",
  },
};

const bashTool = LlmTool(
  name: bashToolName,
  description:
      "Execute a bash command in the chat's persistent shell, which starts in "
      "the workspace directory and keeps its state between commands: a `cd` or "
      "an export made by one command is still there for the next.",
  schema: {
    "type": "object",
    "properties": {
      ..._bashCommonArgs,
      "restart": {
        "type": "boolean",
        "description":
            "Restart the shell before running, discarding any directory a "
            "`cd` moved it to and anything an export gave it. Use it when a "
            "command's failure looks like the shell's state is the problem.",
      },
    },
    "required": ["command"],
  },
);

/// [bashTool] as a sub-agent is offered it: the commands run one-shot, so
/// there is no state the `restart` could drop and none the description could
/// promise.
const bashToolOneShot = LlmTool(
  name: bashToolName,
  description:
      "Execute a bash command. Every command runs in a fresh subshell that "
      "starts in the workspace directory, so a `cd` or an export does not "
      "carry over to the next command: prefix what it needs, or use absolute "
      "paths.",
  schema: {
    "type": "object",
    "properties": _bashCommonArgs,
    "required": ["command"],
  },
);

class BuiltinOptions {
  const BuiltinOptions({
    this.stepLimit = 40,
    this.commandTimeout = const Duration(minutes: 3),
    this.maxAttempts = 4,
    this.retryBackoff = const Duration(seconds: 1),
    this.maxConcurrentSubAgents = 8,
    this.maxConcurrentLlmRequests = 4,
    this.rateLimitRetryBudget = const Duration(minutes: 5),
  });

  /// How many model calls one turn may make. Upstream defaults to no limit and
  /// leans on a cost limit instead; a chat has someone waiting, so it counts
  /// steps.
  final int stepLimit;
  final Duration commandTimeout;

  /// How many times a failed request is tried again before the turn gives up,
  /// and the first wait between two — it doubles after that, so the defaults
  /// spend 7s waiting in total. Deliberately short for the parent: the
  /// controller carries a failed turn on itself, and one attempt here plus its
  /// retry rounds there is the same patience without a second mechanism.
  /// Sub-agents keep the default, a failed worker being a tool result the
  /// parent can redo rather than a turn to give up on. Applies to retryables
  /// other than 429; a 429 is governed by the shared [RateLimitGate] and
  /// [rateLimitRetryBudget].
  final int maxAttempts;
  final Duration retryBackoff;

  /// How many `task` calls in one message run at once. A deep-research turn
  /// can fan out to 75 sub-agents; 8 concurrent keeps provider rate limits
  /// in reach without serializing the whole batch. Bounds long-lived agent
  /// parallelism, distinct from [maxConcurrentLlmRequests] which bounds the
  /// in-flight request count — one sub-agent makes up to [stepLimit] calls.
  final int maxConcurrentSubAgents;

  /// How many [LlmClient.stream] calls may be in flight at once across the
  /// parent agent and every sub-agent it spawns. A [RateLimitGate] enforces
  /// it per turn; the gate also coordinates 429 backoff so a fan-out doesn't
  /// each-retry-into the same rate limit.
  final int maxConcurrentLlmRequests;

  /// How long 429 retries continue through the shared cooldown before the
  /// agent gives up. Other retryables (503, connection drops) keep
  /// [maxAttempts].
  final Duration rateLimitRetryBudget;

  /// What the parent agent runs with: one attempt per request, since the
  /// controller retries a failed turn itself. Everything else unchanged — the
  /// [stepLimit], the timeouts, the concurrency caps.
  BuiltinOptions get parent => BuiltinOptions(
        stepLimit: stepLimit,
        commandTimeout: commandTimeout,
        maxAttempts: 1,
        retryBackoff: retryBackoff,
        maxConcurrentSubAgents: maxConcurrentSubAgents,
        maxConcurrentLlmRequests: maxConcurrentLlmRequests,
        rateLimitRetryBudget: rateLimitRetryBudget,
      );

  /// The same options under a turn's own step limit. Null leaves what this
  /// holds — the backend's answer, which the turn can only name a value for,
  /// not widen past.
  BuiltinOptions copyWithStepLimit(int? stepLimit) => stepLimit == null
      ? this
      : BuiltinOptions(
          stepLimit: stepLimit,
          commandTimeout: commandTimeout,
          maxAttempts: maxAttempts,
          retryBackoff: retryBackoff,
          maxConcurrentSubAgents: maxConcurrentSubAgents,
          maxConcurrentLlmRequests: maxConcurrentLlmRequests,
          rateLimitRetryBudget: rateLimitRetryBudget,
        );
}

/// A chat's conversation as the model sees it. Held per chat and outliving a
/// turn, which is what makes the next prompt a continuation rather than a
/// fresh task.
///
/// **What it holds is what `projectionOf` would build out of `conv.jsonl`**, and
/// [forTurn] is the only exception, for the length of one turn. Nothing of the
/// machine's state rides on it: the directory a command left the shell in is a
/// field on the result, and the projection words the change from it.
class BuiltinSession {
  final List<LlmMessage> messages = [];

  bool get isFresh => messages.isEmpty;

  /// The conversation behind the system block: what [projectionOf] builds and
  /// what parity compares, the scaffolding above it being rewritten per turn.
  List<LlmMessage> get conversation =>
      messages.skipWhile((m) => m.role == LlmRole.system).toList();

  /// The ids of the log messages whose projected wording the conversation
  /// holds — the covered prefix of [coveredEntries] conversation entries,
  /// which is everything before the live tail of the turn running now. How a
  /// sync knows what the log has gained since the session was last at it:
  /// everything after these ids is either the tail to confirm or the log's
  /// new wording to append. Set by the fills that word whole histories; see
  /// `BuiltinBackend._sessionOf`.
  List<String> covered = const [];

  /// How many conversation entries [covered] worded.
  int coveredEntries = 0;

  /// The live tail: what the last turn appended beyond the covered prefix.
  List<LlmMessage> get tail =>
      conversation.sublist(coveredEntries);

  /// The fill's bookkeeping: [messages] are the log span this conversation
  /// words, one id to a message whatever the wordings a message words.
  void coveredBy(List<Message> messages) {
    covered = [for (final message in messages) message.id];
    coveredEntries = conversation.length;
  }

  /// The covered prefix grew by [entries] wordings worded over [ids] on the
  /// log — after a sync confirmed, or appended, those entries.
  void advance(int entries, List<String> ids) {
    coveredEntries += entries;
    covered = [...covered, ...ids];
  }

  /// Put the conversation back into a session that does not have it — one
  /// rewound, or one belonging to a chat opened after a restart. `project` is
  /// what builds the argument, out of what `conv.jsonl` kept.
  void replaceWith(Iterable<LlmMessage> conversation) => messages
    ..clear()
    ..addAll(conversation);

  /// Replace everything from [from] on with [turn]. How a running turn puts
  /// what it has said into the conversation: it is rebuilt from the turn's own
  /// parts after every step rather than appended to, so there is no second
  /// assembly of it to drift from what the log would rebuild.
  void replaceTurn(int from, Iterable<LlmMessage> turn) => messages
    ..removeRange(from, messages.length)
    ..addAll(turn);

  /// Run [turn] with [message] in the conversation, and take it back out when
  /// the turn ends however it ends.
  ///
  /// For the one thing a turn needs the model to see that nobody said and
  /// nothing logs — see `resume`. Left in, it would be a message no reload
  /// could rebuild, and every later turn would send a conversation the log
  /// disagrees with. By index rather than by value: the messages are freezed,
  /// so an identical one earlier in the conversation would be removed instead.
  Stream<T> forTurn<T>(LlmMessage message, Stream<T> Function() turn) async* {
    final at = messages.length;
    messages.add(message);
    try {
      yield* turn();
    } finally {
      messages.removeAt(at);
    }
  }
}

/// The body of the system prompt as the message a turn sends, so the turn and
/// the warm-up that caches it cannot build two different strings. One function
/// for the reason [agentTools] is one: this message is the whole of what the
/// prefill's key is over, and an argument added at one site and not the other
/// leaves a warmed prefix no chat ever sends. The live turn is
/// [BuiltinAgent._setSystemPrompt]; the cache is `createLocalPrefill`.
LlmMessage agentSystemMessage({
  required String platform,
  Profile? profile,
  Tone tone = Tone.none,
  bool citations = false,
  required AgentCapabilities caps,
  List<PromptDocument> skills = const [],
  bool oneShot = false,
}) =>
    LlmMessage(
      role: LlmRole.system,
      text: systemPrompt(
        platform: platform,
        profile: profile,
        tone: tone,
        citations: citations,
        caps: caps,
        skills: skills,
        oneShot: oneShot,
      ),
    );

/// The tools a turn offers, given what this device and this agent allow. One
/// function because the model's tool schemas are rendered into the prompt and
/// so are part of what the prefill cache warms: a turn and its warm-up building
/// two slightly different lists would cache a prefix no turn ever sends. The
/// live turn is [BuiltinAgent._tools]; the cache is `LocalPrefill`.
///
/// [skills] is the whole library's skill list, not the model-invocable half:
/// both halves of the flag are decided where they are read, so one caller
/// passes one list.
List<LlmTool> agentTools({
  required AgentCapabilities caps,
  List<PromptDocument> skills = const [],
  required bool offerMemory,
  bool oneShot = false,
}) =>
    [
      file_tool_defs.readTool,
      file_tool_defs.writeTool,
      file_tool_defs.editTool,
      if (caps.commands) (oneShot ? bashToolOneShot : bashTool),
      if (caps.ask) askTool,
      if (caps.task) taskTool,
      if (caps.webSearch) ...[websearchTool, webfetchTool],
      if (skills.any((s) => s.modelInvocable && !s.isCallback)) skillTool,
      if (caps.artifact) artifactTool,
      if (!oneShot) ...[planAddTool, planNextTool, planDoneTool],
      // Presenting parks the turn on the panel's answer, so it rides `ask`
      // (a headless turn's takes fold out of caps) and the artifact's
      // publish path; a sub-agent's missing `saveArtifact` withholds the
      // rest, the way it withholds `artifact`.
      if (caps.presentPlan) presentPlanTool,
      if (caps.createSkill) createSkillTool,
      // Triggers ride the turn itself: only a top-level turn is its own
      // chat's, so only it may register.
      if (caps.trigger && !oneShot) ...triggerToolDefs,
      if (offerMemory)
        ...[
          memorySaveTool,
          memorySearchTool,
          memoryUpdateTool,
          memoryDeleteTool,
        ],
    ];

/// The agent loop: ask the model, run the command it asked for, show it the
/// result, repeat until it says it is done.
///
/// The skeleton is mini-swe-agent's `DefaultAgent`, ported; the termination
/// protocol is deliberately not — see AGENTS.md, "The agent loop".
class BuiltinAgent {
  BuiltinAgent({
    required this.session,
    this.viewer,
    required this.client,
    required this.shell,
    this.oneShot = false,
    required this.fs,
    required this.workspace,
    required this.projectWorkspace,
    this.environment = const {},
    required this.model,
    required this.approve,
    required this.answer,
    this.options = const BuiltinOptions(),
    this.approveMode = ApproveMode.ask,
    this.classifier,
    this.temperature,
    this.reasoningEffort,
    this.subAgentRunner,
    this.rateLimitGate,
    this.caps = AgentCapabilities.full,
    this.sharedWorkspace = true,
    this.project,
    this.skills = const [],
    this.webSearch,
    this.profile,
    this.tone = Tone.none,
    this.citations = false,
    this.saveArtifact,
    this.packageSkill,
    this.registerTrigger,
    this.onShellOutput,
    this.onUsage,
    this.loadResource = noResources,
    this.memory = MemorySettings.off,
    this.instructions = const [],
    this.recall = "",
    this.pinned = "",
    this.index = "",
    this.memoryStore,
    this.memoryChat,
    this.sandboxHelper,
    this.permissions = const [],
    this.writableDirs = const [],
    this.sandboxReprompt = true,
    this.claimInstruction,
  });

  /// Who this turn answers as: null the house, or the member's bare name the
  /// room routed the say to — the session is worded for them, and the live
  /// prompt's wording must match what a reload rebuilds, so the viewer rides
  /// the agent the way the session does.
  final String? viewer;

  /// Marks an instruction file as first-reached in the conversation, as a
  /// nested `AGENTS.md` read above a file mid-turn is pulled in; returning
  /// true means this agent's turn is the one that records it. Held by the
  /// backend over what the turn's history names, so one conversation records
  /// a file once. Null — every sub-agent's case, having no conversation to
  /// claim against and no events that reach the room — treats every finding
  /// as new, which its own transcript is free to say.
  final bool Function(String path)? claimInstruction;

  /// The sandbox helper a test hands in, where the shell is a fake with no
  /// driver behind it. The agent reads the real one through
  /// [Shell.driverSandboxHelper]; this is the test seam for it, which is why
  /// it is nullable and the real answer wins when both exist.
  @visibleForTesting
  final SandboxHelper? sandboxHelper;

  /// The turn's standing rules, merged chat over project over app by the
  /// repository. Consulted in [_runGated] before the classifier and the
  /// banner; grown at runtime by an "Allow in Chat" or "Allow in Project"
  /// banner answer, through [grantRuntimeRule].
  List<PermissionRule> permissions;

  /// What this turn's sandboxed commands may additionally write to, beside
  /// the workspace — the rules' writes plus the project's writableDirs. Read
  /// by [sandboxFor] per command, so a mid-turn grant reaches the next run.
  final List<String> writableDirs;

  /// Whether a sandbox-denied write is offered back as an approval. Off
  /// reports the denial and moves on.
  final bool sandboxReprompt;

  /// Rules granted mid-turn by a banner answer. They sit in front of the
  /// standing list — the user answered while watching this exact call — and
  /// die with the turn, the standing copies being persisted by the backend.
  final List<PermissionRule> _runtimeRules = [];

  /// Adds a rule at the front of the evaluation, from a banner answer this
  /// turn is still running under, stamped as this turn's own.
  void grantRuntimeRule(PermissionRule rule) =>
      _runtimeRules.insert(0, rule.copyWith(origin: PermissionTier.runtime));

  /// What decided the call whose result is being composed, the tiers that
  /// spoke, and the verdict itself — set by every decision site in the gate
  /// and read by [_ran] onto the result it reports. Null where the mode's
  /// default posture put the call behind the banner: the banner's own part
  /// is the record then, and the answer that follows stamps it anew.
  ({PermissionSource source, List<PermissionTier> tiers,
          PermissionDecision decided})?
      _decision;

  /// Directories a re-prompt banner agreed to, live for the rest of the
  /// turn — [sandboxFor] composes them into every command's grant, so an
  /// "Allow in Chat" on a denial covers the next command without a banner.
  /// The durable copies are the repository's to persist.
  final Set<String> _runtimeDirs = {};

  /// Grants [dirs] for the rest of this turn.
  void grantRuntimeDirs(Iterable<String> dirs) => _runtimeDirs.addAll(dirs);

  /// The confinement a command runs under, from the shell's driver. Read per
  /// turn rather than held: the driver is resolved per command in the shell,
  /// and the sandbox is only ever offered where the machine itself is the
  /// driver — a guest's rootfs is already the boundary, and Android's
  /// per-app sandbox is the OS's.
  CommandSandbox? sandboxFor() {
    final helper = sandboxHelper ?? shell.driverSandboxHelper;
    if (helper == null) return null;
    final tmp = shell.tmpDirFor(workspace);
    return CommandSandbox(
      workspace: workspace,
      tmp: tmp,
      home: shell.machineHome,
      extraWrites: [...writableDirs, ..._runtimeDirs],
    );
  }

  /// Whether this build's host platform models its shell as POSIX. Windows
  /// `cmd` is not, and its commands are escalated rather than parsed; the
  /// flag reaches the parse from the platform the shell names.
  bool get platformIsWindows => shell.platformIsWindows;

  final BuiltinSession session;

  final LlmClient client;

  final Shell shell;

  /// Whether the agent's commands run one-shot — each in a subshell that is
  /// gone when it finishes, no state carried over — rather than the chat's
  /// own persistent shell. A sub-agent's: a fan-out of workers wants
  /// concurrency, not a shell to race over. It reaches the shell at
  /// [shell.start] and the prompt at [agentSystemMessage], the two halves the
  /// model would otherwise be told different things about.
  final bool oneShot;

  /// Where an attachment's bytes come from when the turn being opened is
  /// projected. Defaulted because a sub-agent has no chat under it to read
  /// from; `BuiltinBackend` passes the store's.
  final ResourceLoader loadResource;

  /// What this turn reads and remembers. Only the `nested` half is consulted
  /// here: the instructions block was loaded by the backend before the agent
  /// existed, and the rest of the subsystem is later work.
  final MemorySettings memory;

  /// The AGENTS.md files loaded for this chat's workspaces, already read.
  /// Empty when the gate is off or nothing was found; rendered into the
  /// second system message either way, so the cacheable body above it never
  /// changes.
  final List<InstructionFile> instructions;

  /// The memories recalled for this turn, already rendered as a block. Empty
  /// when the gate is off, nothing matched, or the store was empty. The
  /// backend queried the store before the agent existed, for the reason
  /// [instructions] was loaded there.
  final String recall;

  /// The pinned memories, in full, and the rest of the store as an index —
  /// the always-loaded half of what [recall] loads on demand. Both empty when
  /// the gate is off or the store is empty, beside [recall].
  final String pinned;
  final String index;

  /// The project's memory store the memory tools talk to, or null where they
  /// are not offered: auto-memory off, the agent-tool gate off, or a sub-agent
  /// (which runs with none of the subsystem). Null also here is what takes the
  /// tools off the list in [_tools].
  final MemoryStore? memoryStore;

  /// What a saved memory is stamped with: the chat that wrote it. Beside
  /// [memoryStore] or neither.
  final String? memoryChat;

  /// AGENTS.md paths already in front of the model, seeded from
  /// [instructions]. A nested file found on a read is added, so the same one
  /// is never injected twice into a turn.
  Set<String> get _loadedInstructions =>
      _loadedInstructionPaths ??= {
        for (final file in instructions) file.path,
      };
  Set<String>? _loadedInstructionPaths;

  /// The filesystem the file tools (`read`/`write`/`edit`) and the artifact
  /// tool's path resolution operate on. The same one `AppConfig` holds, so it
  /// is `fileSystemIo` on desktop and Android, `fileSystemWeb` (IndexedDB) in
  /// a browser — and the file tools work everywhere, unlike `bash`.
  final FileSystem fs;

  /// The chat's own directory, and where the shell starts.
  final String workspace;

  /// The project's workspace: the one every chat in the project shares where
  /// one is shared, the chat's own where one is not, resolved by the caller.
  /// Not the working directory: what a turn puts here is what it means other
  /// chats to find.
  final String projectWorkspace;

  /// The project's own command variables, layered over the app-level ones by
  /// the shell. The app-level ones are the shell's to read on each command,
  /// for the reason they are settings; these travel here because they were
  /// resolved where the project was, which is the backend's.
  final Map<String, String> environment;

  final String model;
  final BuiltinOptions options;
  final double? temperature;
  final String? reasoningEffort;

  /// How the agent handles a command before it runs. Per turn rather than part
  /// of [options]: it is the chat's own setting, and it arrives with the
  /// prompt.
  final ApproveMode approveMode;

  /// Classifies a command as safe enough to run without asking, when
  /// [approveMode] is [ApproveMode.auto]. Null falls back to asking for every
  /// command — [NoClassifier] does the same, so the backend passes that when no
  /// classifier model is configured.
  final PermissionClassifier? classifier;

  /// Asks the user whether a command may run. Called in [ApproveMode.ask], and
  /// in [ApproveMode.auto] when the classifier says [PermissionDecision.ask].
  final Future<ApprovalResponse> Function(ToolApproval approval) approve;

  /// Puts the model's own questions to the user. One answer per question, null
  /// where they answered nothing.
  final Future<List<String?>> Function(AskRequest request) answer;

  /// Spawns sub-agents for `task` calls. Null where the agent is itself a
  /// sub-agent: sub-agents do not spawn their own sub-agents.
  final SubAgentRunner? subAgentRunner;

  /// Bounds in-flight `LlmClient.stream` calls across the parent and its
  /// sub-agents and coordinates 429 backoff. Null where the agent is built
  /// directly against a raw [LlmClient] (tests); the per-agent
  /// [BuiltinOptions.maxAttempts] path then governs 429s too.
  final RateLimitGate? rateLimitGate;

  /// What this agent is offered, resolved once by the caller: the platform's
  /// facts minus a headless turn's takes and a built-in project's. Sub-agents
  /// pass the parent's `caps.unattended` — they run unattended, so they ask
  /// nothing, fan out nothing, and publish nothing. Where the platform itself
  /// cannot run something ([shell], [webSearch], a missing [subAgentRunner] or
  /// [saveArtifact]), it is dropped below even if [caps] holds it.
  final AgentCapabilities caps;

  /// Whether the project's workspace is shared between its chats. When false,
  /// the chat's own workspace is the one the prompt names, and the
  /// shared-workspace sentence is absent.
  final bool sharedWorkspace;

  /// The project this agent's turn is in, so the shell driver can resolve a
  /// per-project rootfs instance for an isolated built-in. Null for the
  /// default project and user projects.
  final String? project;

  /// The whole skill library, both invocation halves of it. The system prompt
  /// lists the model-invocable ones, the `skill` tool refuses the rest, and a
  /// sub-agent gets the same list — a skill's workflow is as much a worker's
  /// job as the parent's.
  final List<PromptDocument> skills;

  /// Web search and fetch. Null where neither is reachable — a browser sees
  /// `UnavailableWebSearch` and the tools are dropped the way `bash` is when
  /// there is no shell.
  final WebSearch? webSearch;

  /// The user's profile, appended to the system prompt as "About the user".
  /// Null means nothing is added. Rewritten every turn with the rest of the
  /// system prompt.
  final Profile? profile;

  /// How the turn words its replies, resolved with the profile. Rewritten
  /// every turn with the rest of the system prompt; a sub-agent gets the
  /// parent's, so a worker words its part the way the chat is set to.
  final Tone tone;

  /// Whether the turn numbers the web pages it drew on and lists them at the
  /// end of the reply.
  final bool citations;

  /// Publishes an artifact from a workspace path to the chat's `artifacts/`
  /// dir and returns the id. Null where the agent is a sub-agent: sub-agents run
  /// headless with no viewer surface, so the tool is dropped for them the way
  /// `ask_user` is. The closure resolves the path (with `project:` prefix
  /// support) and copies the dir; the agent just passes the args through.
  /// [entryFile] is the file inside the copied dir the viewer opens, which
  /// the store styles at publish time.
  final Future<String> Function(String path, String entryFile,
      {String? artifactId})? saveArtifact;

  /// Packages a skill drafted in the workspace and stages the `.skill` for the
  /// user to install. Null where the agent is a sub-agent: a worker does not
  /// offer skills for install. Returns the install id.
  final Future<({String installId, String name})> Function(
      String path, String? name)? packageSkill;

  /// What a running command has printed, as it prints it, for the block under
  /// its label. Null where the agent is a sub-agent — a worker's commands are
  /// not watched — and null is the only thing that stops the reporting. The
  /// agent holds the stream, the callback decides what showing it is; it does
  /// not reach the session, and the pair completing is what the conversation
  /// keeps.
  final void Function(String? callId, String text)? onShellOutput;

  /// What each response cost, as the provider reported it. Turn-scoped view
  /// state rather than a record: the newest completion is the newest request's
  /// fact, and the newest request is what measures the session as it stands.
  /// Null where the provider reports nothing, which is every completion a
  /// test fakes unless it says otherwise.
  final void Function(LlmUsage usage)? onUsage;

  /// What the trigger tools run against — a registry over the app's own
  /// trigger list — or null, which withholds the trio the way a missing
  /// [subAgentRunner] withholds `task`. Null on a sub-agent: a trigger's
  /// fire sends into *this* chat, which is one a worker is not.
  final TriggerRegistry? registerTrigger;

  /// [caps] with the platform's facts applied where [caps] cannot know them:
  /// a tool the device cannot run is not offered even if the turn was, and a
  /// sub-agent's missing [subAgentRunner] or [saveArtifact] withholds `task`
  /// and `artifact` the way [AgentCapabilities.unattended] does from the front.
  AgentCapabilities get _offered => AgentCapabilities(
        commands: caps.commands && shell.canRunCommands,
        webSearch: caps.webSearch && (webSearch?.available ?? false),
        ask: caps.ask,
        task: caps.task && subAgentRunner != null,
        artifact: caps.artifact && saveArtifact != null,
        createSkill: caps.createSkill && packageSkill != null,
        trigger: caps.trigger && registerTrigger != null,
      );

  /// What the model may call, and what the system prompt says. One value for
  /// both, so the prompt cannot advertise a tool the list does not carry.
  /// `skill` is dropped where no skill allows the model itself.
  /// `read`/`write`/`edit` are always offered — they work on the `FileSystem`,
  /// which exists on every platform.
  List<LlmTool> get _tools => agentTools(
        caps: _offered,
        skills: skills,
        offerMemory: memoryStore != null,
        oneShot: oneShot,
      );

  bool _cancelled = false;
  ShellRun? _running;

  /// Circuit breaker for auto mode: too many escalations means the classifier
  /// is not confident enough to be useful, so the turn falls back to asking.
  int _consecutiveAsks = 0;
  int _totalAsks = 0;
  bool _autoPaused = false;

  /// One step's scratch: what the model call produced. Fields rather than
  /// out-parameters because an `async*` method has no return value of its own,
  /// and the turn is single-threaded.
  LlmCompletion? _completion;
  Object? _queryError;
  ShellResult? _commandResult;

  /// Stop the turn. Kills whatever is running: an aborted turn that leaves a
  /// build going is not aborted, and a fan-out of sub-agents is not either.
  Future<void> cancel() async {
    _cancelled = true;
    await _running?.kill();
    await subAgentRunner?.cancel();
  }

  /// [prompt] is the message being logged for this turn, projected rather than
  /// worded here — see [projectionOf]. [mayDress] is whether it may dress as
  /// the task — the viewer's first own mail, decided by the caller against
  /// the history it holds, the decision a whole-span walk would make.
  Stream<AgentEvent> run(Message prompt,
      {String? agentPrompt, bool mayDress = false}) async* {
    await _openTurn(prompt, mayDress, agentPrompt);
    yield* _recorded(_loop)();
  }

  /// [run] without the task: the session is already holding everything the
  /// interrupted turn had done, so all this adds is the reason it is being
  /// asked again.
  ///
  /// Not even that where the session ends in a user message, which is a turn
  /// killed before the model was ever called. Telling a model it was cut off
  /// part-way when there is nothing of its own above is a contradiction, and
  /// small models are what this app is for.
  ///
  /// **The reason is this turn's**, so it goes in through [BuiltinSession.forTurn]
  /// and is gone when the turn ends — the way the system prompt is rewritten
  /// rather than added to. Nothing logs it, so a session that kept it would
  /// hold a message no reload could rebuild; see "The projection" in
  /// `lib/domain/AGENTS.md` for what that cost.
  Stream<AgentEvent> resume({String? agentPrompt}) async* {
    _setSystemPrompt(agentPrompt);
    final turn = _recorded(_loop);
    // Wrapped either way: the branch decides whether the reason goes in, not
    // whether the turn is recorded.
    yield* session.messages.lastOrNull?.role == LlmRole.user
        ? turn()
        : session.forTurn(
            const LlmMessage(role: LlmRole.user, text: continueTask), turn);
  }

  /// Every event the turn emits, through [_said] on its way out. A `yield`
  /// suspends the loop until its consumer takes the event, so everything a step
  /// produced is a part before the next step builds its request.
  /// [turn]'s events, through a recorder on their way out, with the session's
  /// turn half rebuilt from them as they land.
  ///
  /// Both pieces of state are the closure's rather than the agent's: a turn is
  /// what has one, and holding them on the agent would have two turns on one
  /// agent writing over each other. The boundary is read here because by now
  /// everything the turn opens with — the prompt, a resume's reason — is in
  /// place; the parts start empty because whatever came before is already in
  /// the conversation, projected.
  Stream<AgentEvent> Function() _recorded(Stream<AgentEvent> Function() turn) =>
      () async* {
        final said = TurnRecorder.parts();
        final from = session.messages.length;
        void sayWhatWasSaid() {
          said.flushDeltas();
          session.replaceTurn(from, assistantMessages(said.parts));
        }

        _sayWhatWasSaid = sayWhatWasSaid;
        try {
          await for (final event in turn()) {
            said.handle(event);
            yield event;
          }
        } finally {
          // Once more at the end, for the step that produced no further
          // request to be built for — and on a cancel, so the session holds
          // what did happen.
          sayWhatWasSaid();
          said.dispose();
        }
      };

  /// The running turn's rebuild, set by [_recorded] and called by the loop.
  void Function() _sayWhatWasSaid = _nothingSaidYet;

  static void _nothingSaidYet() {}

  /// This turn's half of the conversation, rebuilt from what it has said. The
  /// only thing that writes to [session] during a turn, and it writes what
  /// `projectionOf` would build out of the same parts once they are on disk.
  Stream<AgentEvent> _loop() async* {
    for (var step = 0; step < options.stepLimit; step++) {
      if (_cancelled) break;
      _sayWhatWasSaid();

      // One response per step, named before it starts: what streams out of it
      // is stamped with this, so the turn can be handed back to a provider a
      // response at a time.
      yield ResponseStart(const Uuid().v4());

      _completion = null;
      _queryError = null;
      yield* _query();
      if (_cancelled) break;
      if (_queryError != null) {
        yield ErrorEvent("$_queryError",
            retryable: _queryError is LlmException && (_queryError as LlmException).retryable);
        break;
      }
      final completion = _completion;
      if (completion == null) break;

      // A reply with no tool calls is the finished answer — the text was
      // already streamed as TextDelta by _query. This is the native API
      // contract models are trained on, and works with or without a shell.
      if (completion.message.toolCalls.isEmpty) break;

      yield* _executeAll(completion.message.toolCalls);
      if (_cancelled) break;

      if (step == options.stepLimit - 1) {
        yield StepLimitEvent(options.stepLimit);
      }
    }

    yield const DoneEvent();
  }

  Future<void> _openTurn(
      Message prompt, bool mayDress, String? agentPrompt) async {
    _setSystemPrompt(agentPrompt);
    // The wording the live turn sends is the wording a reload rebuilds: both
    // call the projection, and the dress decision — may this message dress —
    // is the caller's, computed against the history it holds: the viewer's
    // first own mail dresses, and a whole-span walk decides the same first;
    // see "The room and its participants".
    session.messages.addAll(await projectionOf([prompt],
        first: mayDress, viewer: viewer, load: loadResource));
  }

  /// The system prompt is rewritten every turn rather than once, so an
  /// `@agent` mention applies to the turn that used it whether or not the
  /// session is new — and so a resumed turn runs under the prompt the turn it
  /// is continuing ran under.
  ///
  /// Two messages, not one: the body is the same string for every chat on this
  /// device and the workspace is not, so splitting them leaves the body a
  /// prefix two chats share to the byte — which is what the warm-up warms and
  /// what a restore can find. See [turnPrompt]. Two only as far as the KV keys:
  /// a chat template renders one system block, so `mergeLeadingSystem` joins
  /// them on the way out.
  void _setSystemPrompt(String? agentPrompt) {
    final caps = _offered;
    final turn = turnPrompt(
      workspace: workspace,
      projectWorkspace: projectWorkspace,
      agentPrompt: agentPrompt,
      instructions: renderInstructions(instructions),
      pinned: pinned,
      index: index,
      recall: recall,
      canRunCommands: caps.commands,
      sharedWorkspace: sharedWorkspace,
      projectHome: shell.projectHome,
      guestRoot: shell.guestRoot,
      homePath: shell.homeFor(projectWorkspace),
    );
    final head = [
      agentSystemMessage(
        platform: shell.platformDescription,
        profile: profile,
        tone: tone,
        citations: citations,
        caps: caps,
        skills: skills,
        oneShot: oneShot,
      ),
      if (turn.isNotEmpty) LlmMessage(role: LlmRole.system, text: turn),
    ];
    final replacing =
        session.messages.takeWhile((m) => m.role == LlmRole.system).length;
    session.messages.replaceRange(0, replacing, head);
  }

  /// Every call the model made gets an answer, including the ones we never ran:
  /// a provider that sees a tool call with no result rejects the next turn.
  ///
  /// `task` calls run concurrently — the deep-research prompt fans out up to
  /// 75 at once — capped by [BuiltinOptions.maxConcurrentSubAgents]. Every
  /// other call runs in order, so a `bash` before a `task` is done first and
  /// a `bash` after waits for the fan-out. The session messages are answered
  /// in the calls' original order regardless, so the tool results pair up.
  Stream<AgentEvent> _executeAll(List<LlmToolCall> calls) async* {
    if (calls.isEmpty) return;

    final taskCalls = calls
        .where((c) => c.name == taskToolName && subAgentRunner != null && shell.canRunCommands)
        .toList();

    // Run every non-`task` call in order first. A command before a fan-out
    // has to be done before the fan-out starts, and one after has to wait for
    // it — the alternative, interleaving, would race a sub-agent against a
    // command it might depend on.
    for (final call in calls) {
      if (_cancelled) {
        // Task calls are answered at the end; a task call that was never
        // collected (no sub-agent runner) is answered here instead.
        if (call.name != taskToolName || taskCalls.isEmpty) {
          // The call as well as the answer: a result whose call is not in the
          // parts is a result the projection has nothing to pair it to, and
          // drops. The model did ask for this one — it just never ran.
          yield ToolCallEvent(ToolCall(
              id: call.id, name: call.name, argumentsJson: call.argumentsJson));
          yield ToolResultEvent(_ran(call, const ShellResult.failed(notExecuted)));
        }
        continue;
      }

      if (call.name == taskToolName) continue;

      final doing = runningTool(call.name);
      if (doing != null) yield StatusEvent(doing);

      if (call.name == readToolName) {
        yield* _read(call);
        continue;
      }

      if (call.name == writeToolName) {
        yield* _write(call);
        continue;
      }

      if (call.name == editToolName) {
        yield* _edit(call);
        continue;
      }

      if (call.name == askToolName) {
        yield* _ask(call);
        continue;
      }

      if (call.name == skillToolName) {
        yield* _skill(call);
        continue;
      }

      if (call.name == websearchToolName) {
        yield* _webSearch(call);
        continue;
      }

      if (call.name == webfetchToolName) {
        yield* _webFetch(call);
        continue;
      }

      if (call.name == memorySaveToolName) {
        yield* _memorySave(call);
        continue;
      }

      if (call.name == memorySearchToolName) {
        yield* _memorySearch(call);
        continue;
      }

      if (call.name == memoryUpdateToolName) {
        yield* _memoryUpdate(call);
        continue;
      }

      if (call.name == memoryDeleteToolName) {
        yield* _memoryDelete(call);
        continue;
      }

      if (call.name == artifactToolName && saveArtifact != null) {
        yield* _artifact(call);
        continue;
      }

      if (call.name == planAddToolName && !oneShot) {
        yield* _planAdd(call);
        continue;
      }

      if (call.name == planNextToolName && !oneShot) {
        yield* _planNext(call);
        continue;
      }

      if (call.name == planDoneToolName && !oneShot) {
        yield* _planDone(call);
        continue;
      }

      if (call.name == presentPlanToolName && _offered.presentPlan) {
        yield* _presentPlan(call);
        continue;
      }

      if (call.name == createSkillToolName && packageSkill != null) {
        yield* _createSkill(call);
        continue;
      }

      if (call.name == triggerSetName && registerTrigger != null) {
        yield* _triggerSet(call);
        continue;
      }

      if (call.name == triggerRemoveName && registerTrigger != null) {
        yield* _triggerRemove(call);
        continue;
      }

      if (call.name == triggerListName && registerTrigger != null) {
        yield* _triggerList(call);
        continue;
      }

      if (call.name != "bash") {
        yield* _reject(call, unknownTool(call.name, _tools.map((t) => t.name)));
        continue;
      }

      final command = _commandOf(call);
      if (command == null) {
        yield* _reject(
            call,
            "The bash tool takes {\"command\": \"...\"}; that argument was missing "
            "or was not valid JSON.");
        continue;
      }

      // The command's parse, made once and carried the whole way: the rule
      // gate reads its segments, the deterministic tier reads its answer for
      // the segments, and the run's confinement reads the grant the tier
      // vouched with — one parse and one assessment behind a command rather
      // than three.
      final analysis = ShellCommandAnalysis.parse(command,
          isWindows: platformIsWindows);

      yield ToolCallEvent(ToolCall(
        id: call.id,
        name: "bash",
        argumentsJson: call.argumentsJson,
        argumentsText: command,
      ));

      yield* _runGated(call, call.argumentsJson, "bash",
          () => _execute(call, command, analysis: analysis),
          argumentsText: command, analysis: analysis);
      var result = _commandResult!;
      // The sandbox's answer rides between the result and its report: a
      // denied write is offered back once, the rerun's outcome replacing
      // the denial as what the model and the conversation read. The re-prompt
      // streams its own banner through, the turn recording it like the first.
      yield* sandboxRepromptIfNeeded(call, command, result);
      result = _commandResult!;

      yield ToolResultEvent(_ran(call, result));
    }

    if (taskCalls.isEmpty || _cancelled) {
      // Answer the task calls that never ran, so the next turn is not rejected
      // for missing results.
      for (final call in taskCalls) {
        yield* _reject(call, notStarted);
      }
      return;
    }

    yield* _executeTasks(taskCalls);
  }

  /// Run a batch of `task` calls concurrently, capped to
  /// [BuiltinOptions.maxConcurrentSubAgents]. Results stream as each sub-agent
  /// resolves; the projection pairs each back to its call by id, so finishing
  /// out of order costs nothing.
  Stream<AgentEvent> _executeTasks(List<LlmToolCall> calls) async* {
    final parsed = [for (final call in calls) _taskArgsOf(call)];

    // The calls up front, in the order the model made them. They are one
    // message's worth of calls and the projection reads them back in the order
    // their parts are in — emitted as each sub-agent resolved, they went into
    // the log in finishing order, which is not an order the model ever chose.
    for (var i = 0; i < calls.length; i++) {
      final args = parsed[i];
      yield ToolCallEvent(ToolCall(
        id: calls[i].id,
        name: calls[i].name,
        argumentsJson: calls[i].argumentsJson,
        argumentsText:
            args == null ? null : "@${args.agent}: ${_truncate(args.prompt, 200)}",
      ));
    }

    final controller = StreamController<AgentEvent>();

    Future<void> runOne(int index) async {
      final call = calls[index];
      final args = parsed[index];
      if (args == null) {
        controller.add(ToolResultEvent(_ran(call,
            ShellResult.failed(
                'The $taskToolName tool takes {"agent": "...", "prompt": "..."}.'))));
        return;
      }
      final (:agent, :prompt) = args;
      controller.add(SubAgentStartEvent(
          id: call.id, agent: agent, prompt: _truncate(prompt, 80)));
      final result = await subAgentRunner!.run(agent, prompt, callId: call.id);
      controller.add(SubAgentEndEvent(id: call.id, failed: result.returnCode != 0));
      controller.add(ToolResultEvent(_ran(call, result)));
    }

    // A bounded fan-out: run maxConcurrentSubAgents at a time, starting the
    // next as each finishes. A simple slot pool rather than a package dep.
    final slots = <Completer<void>>[];
    Future<void> acquire() async {
      if (slots.length >= options.maxConcurrentSubAgents) {
        final done = Completer<void>();
        slots.add(done);
        await done.future;
      }
    }

    void release() {
      if (slots.isNotEmpty) {
        slots.removeAt(0).complete();
      }
    }

    final futures = <Future<void>>[];
    for (var i = 0; i < calls.length; i++) {
      futures.add(() async {
        await acquire();
        if (_cancelled) {
          controller.add(ToolResultEvent(_ran(calls[i], const ShellResult.failed(turnStopped))));
          return;
        }
        try {
          await runOne(i);
        } finally {
          release();
        }
      }());
    }

    // Close the controller once every sub-agent has finished, so the
    // `await for` below unblocks and the loop continues.
    final allDone = Future.wait(futures).whenComplete(controller.close);

    // Stream the concurrent sub-agent events out as they resolve.
    await for (final event in controller.stream) {
      yield event;
    }
    await allDone;
  }

  /// Pull `agent` and `prompt` out of a `task` call's arguments, or null when
  /// the JSON is not what the tool takes.
  ({String agent, String prompt})? _taskArgsOf(LlmToolCall call) {
    final agent = stringArg(call.argumentsJson, "agent");
    final prompt = stringArg(call.argumentsJson, "prompt");
    if (agent == null || prompt == null) return null;
    return (agent: agent, prompt: prompt);
  }

  String _truncate(String text, int max) {
    final t = text.trim().replaceAll("\n", " ");
    return t.length <= max ? t : "${t.substring(0, max - 1)}…";
  }

  /// A command's outcome as the result of the call that asked for it: one that
  /// ran, one that was refused, one that was never reached. The directory the
  /// shell was left in rides on it as a fact; the projection words the change.
  /// What the sandbox denied rides on it too, where one ran and denied
  /// something — the wording is `observation`'s, so the model reads it beside
  /// the output it belongs to.
  ToolResult _ran(LlmToolCall call, ShellResult result) {
    final decision = _decision;
    _decision = null;
    return ToolResult(
      callId: call.id,
      returnCode: result.returnCode,
      output: result.output,
      exceptionInfo: result.exceptionInfo,
      cwd: result.cwd,
      violations: result.violations,
      decidedBy: decision?.source,
      decidedTier: decision?.tiers ?? const [],
      decided: decision?.decided,
    );
  }

  /// The model asking the user something. The call and its answers are a pair
  /// like any other, so a finished chat still shows what was asked and picked.
  Stream<AgentEvent> _ask(LlmToolCall call) async* {
    final questions = askQuestionsFrom(call.argumentsJson);
    if (questions.isEmpty) {
      yield* _reject(call, askFormatError);
      return;
    }

    yield ToolCallEvent(
        ToolCall(id: call.id, name: call.name, argumentsJson: call.argumentsJson));
    final request = AskRequest(
        id: call.id,
        questions: questions,
        argumentsJson: call.argumentsJson);
    // Emitted before it is awaited, for the same reason an approval is: the
    // panel is where the answers come from.
    yield QuestionRequestEvent(request);
    final answers = askAnswers(questions, await answer(request));

    yield ToolResultEvent(ToolResult(callId: call.id, returnCode: 0, output: answers));
  }

  /// Load a skill. Read-only and instant, so no approval and no running label:
  /// the answer is text the library already holds, and the turn's next step is
  /// whatever the model does with it.
  ///
  /// The refusal for a `disable-model-invocation` skill is deliberate wording
  /// rather than a plain no: the skill is *available*, just not to the model,
  /// and one that is told only "no" will try the workflow by other means.
  Stream<AgentEvent> _skill(LlmToolCall call) async* {
    final name = stringArg(call.argumentsJson, "skill");
    if (name == null) {
      yield* _reject(call, skillFormatError);
      return;
    }
    final arguments = stringArg(call.argumentsJson, "args") ?? "";
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: arguments.isEmpty ? name : "$name $arguments",
    ));

    final document = skills.where((s) => s.name == name).firstOrNull;
    if (document == null) {
      yield ToolResultEvent(_ran(
          call,
          ShellResult.failed(skillUnknown(name, [
            for (final skill in skills)
              if (skill.modelInvocable && !skill.isCallback) skill.name,
          ]))));
      return;
    }
    // A callback's body is the user-facing note, never a procedure for the
    // model to read — the same reason composition refuses to expand it.
    if (!document.modelInvocable || document.isCallback) {
      yield ToolResultEvent(_ran(call, ShellResult.failed(skillReserved(name))));
      return;
    }
    yield ToolResultEvent(
        ToolResult(callId: call.id, returnCode: 0, output: _skillOutput(document, arguments)));
  }

  /// The skill body with its base directory translated to the guest's paths,
  /// where the shell runs inside one, so the model can `cd` to it and run
  /// its scripts.
  String _skillOutput(PromptDocument document, String arguments) {
    var body = skillPrompt(document, arguments);
    for (final MapEntry(:key, :value) in shell.hostToGuestPaths.entries) {
      body = body.replaceAll(key, value);
    }
    return body;
  }

  /// Search the web. Read-only, so no approval — the result is worded the same
  /// way a command's is.
  Stream<AgentEvent> _webSearch(LlmToolCall call) async* {
    final query = stringArg(call.argumentsJson, "query");
    if (query == null) {
      yield* _reject(call,
          'The $websearchToolName tool takes {"query": "..."}.');
      return;
    }
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: query,
    ));
    final result = await webSearch!.search(query);
    yield ToolResultEvent(_ran(call, result));
  }

  /// Fetch a URL. The network rules answer for it — the same family a
  /// `curl` or `wget` segment in a command consults — and the banner is
  /// where one standing answer comes from.
  Stream<AgentEvent> _webFetch(LlmToolCall call) async* {
    final url = stringArg(call.argumentsJson, "url");
    if (url == null) {
      yield* _reject(call,
          'The $webfetchToolName tool takes {"url": "..."}.');
      return;
    }
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: url,
    ));
    yield* _runGated(call, call.argumentsJson, webfetchToolName,
        () => webSearch!.fetch(url),
        argumentsText: url);
    final result = _commandResult!;
    yield ToolResultEvent(_ran(call, result));
  }

  /// Resolve a file-tool path through the workspaces, the guest root and the
  /// shell's home, so every call site carries the translation without
  /// spelling it out.
  String _resolvePath(String path) => resolveWorkspacePath(
      fs, path, workspace, projectWorkspace,
      guestRoot: shell.guestRoot, homePath: shell.homeFor(projectWorkspace));

  /// Read a file. A path the workspaces hold runs without asking, the way
  /// `bash` reads in `never` mode; one that reaches past them is offered to
  /// the user first, on the same terms a command is.
  Stream<AgentEvent> _read(LlmToolCall call) async* {
    final args = readArgsFrom(call.argumentsJson);
    if (args == null) {
      yield* _reject(call,
          'The $readToolName tool takes {"path": "..."}; that argument was missing.');
      return;
    }
    final path = _resolvePath(args.path);
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: args.path,
    ));
    // Held beside the run rather than in it, for the event below: what the
    // read pulled in, if anything. Empty is the honest "nothing" — a denied
    // or gated read never ran, so it pulled nothing in — and it stands in
    // for null, so nothing downstream has to test for it.
    var nested = const <InstructionFile>[];
    Future<ShellResult> run() async {
      final file = fs.file(path);
      if (!await file.exists()) {
        return ShellResult(
            returnCode: -1, output: "", exceptionInfo: "File not found: ${args.path}");
      }
      String content;
      try {
        content = await file.readAsString();
      } on FileSystemException {
        return ShellResult(
            returnCode: -1,
            output: "",
            exceptionInfo: "Not a UTF-8 text file (binary?): ${args.path}. "
                "Inspect binary files with a command instead of $readToolName.");
      }
      final lines = content.split("\n");
      final offset = (args.offset ?? 1).clamp(1, lines.length + 1);
      final limit = args.limit ?? lines.length;
      final end = (offset + limit - 1).clamp(1, lines.length);
      final buf = StringBuffer();
      for (var i = offset; i <= end; i++) {
        buf.writeln("$i: ${lines[i - 1]}");
      }
      final result = buf.toString();
      nested = memory.nested
          ? await findNestedInstructions(
              fs,
              path,
              alreadyLoaded: _loadedInstructions,
              projectWorkspace: projectWorkspace,
              excludes: memory.excludes,
            )
          : const <InstructionFile>[];
      final output = nested.isEmpty
          ? (result.isEmpty ? "(empty file)" : result)
          : "$result\n\n${renderInstructions(nested)}";
      return ShellResult(returnCode: 0, output: output);
    }
    yield* _runFileTool(call, path, readToolName, run);
    // A successful read reports what it reached here, the claim deciding
    // which of the findings are this conversation's first.
    if (nested.isNotEmpty) {
      final fresh = [
        for (final file in nested)
          if (claimInstruction == null || claimInstruction!(file.path)) file.ref,
      ];
      if (fresh.isNotEmpty) yield InstructionsReadEvent(fresh);
    }
  }

  /// Write a file, creating or overwriting. The same gate as [read]: the
  /// workspaces run, the machine is asked.
  Stream<AgentEvent> _write(LlmToolCall call) async* {
    final args = writeArgsFrom(call.argumentsJson);
    if (args == null) {
      yield* _reject(call,
          'The $writeToolName tool takes {"path": "...", "content": "..."}; '
          "those arguments were missing.");
      return;
    }
    final path = _resolvePath(args.path);
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: args.path,
    ));
    Future<ShellResult> run() async {
      await fs.directory(fs.path.dirname(path)).create(recursive: true);
      await fs.file(path).writeAsString(args.content);
      return ShellResult(
          returnCode: 0, output: "Wrote ${args.content.length} bytes to ${args.path}");
    }
    yield* _runFileTool(call, path, writeToolName, run);
  }

  /// Edit a file by exact string replacement. The same gate as [read].
  Stream<AgentEvent> _edit(LlmToolCall call) async* {
    final args = editArgsFrom(call.argumentsJson);
    if (args == null) {
      yield* _reject(call,
          'The $editToolName tool takes {"path": "...", "old_string": "...", '
          '"new_string": "..."}; those arguments were missing.');
      return;
    }
    final path = _resolvePath(args.path);
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: args.path,
    ));
    Future<ShellResult> run() async {
      final file = fs.file(path);
      if (!await file.exists()) {
        return ShellResult(
            returnCode: -1, output: "", exceptionInfo: "File not found: ${args.path}");
      }
      final content = await file.readAsString();
      final count = content.split(args.oldString).length - 1;
      if (count == 0) {
        return ShellResult(returnCode: -1, output: "",
            exceptionInfo: "old_string not found in ${args.path}");
      }
      if (!args.replaceAll && count > 1) {
        return ShellResult(
            returnCode: -1,
            output: "",
            exceptionInfo:
                "old_string appears $count times in ${args.path}; "
                "add context to make it unique or set replace_all.");
      }
      final updated = args.replaceAll
          ? content.replaceAll(args.oldString, args.newString)
          : content.replaceFirst(args.oldString, args.newString);
      await file.writeAsString(updated);
      return ShellResult(
          returnCode: 0, output: "Edited ${args.path}: replaced $count occurrence(s).");
    }
    yield* _runFileTool(call, path, editToolName, run);
  }

  /// Register a trigger. The chat is the turn's own — a trigger fires into
  /// the conversation that registered it — and the registration is watched
  /// the moment the list lands. The model is told what it armed and when.
  Stream<AgentEvent> _triggerSet(LlmToolCall call) async* {
    final registry = registerTrigger;
    final args = decodeArgs(call.argumentsJson);
    if (args == null) {
      yield* _reject(call, triggerSetProblem(null));
      return;
    }
    final draft = triggerDraftFromArgs(args: args);
    if (draft == null) {
      yield* _reject(call, triggerSetProblem(stringArg(call.argumentsJson, "source")));
      return;
    }
    // A file watch is never asked before it fires (and a fire's headless
    // turn runs approveMode never), so the outside paths the read tool
    // raises a banner over are refused here, where the call can still be
    // answered — a watch over `~` or the machine is not a shape the tool
    // takes.
    if (draft.source is FileSource) {
      final outside = [
        for (final path in (draft.source as FileSource).paths)
          if (outsideWorkspaces(fs, _resolvePath(path), workspace, projectWorkspace))
            path,
      ];
      if (outside.isNotEmpty) {
        yield* _reject(
            call,
            "A file trigger watches the workspaces: give workspace-relative "
            "or project:-prefixed paths (${outside.join(", ")} reach past "
            "them).");
        return;
      }
    }
    final label = [
      if (draft.name.isNotEmpty) draft.name,
      draft.source.describe(),
    ].join(" — ");
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: label,
    ));
    try {
      final stored = await registry!.register(
          source: draft.source,
          prompt: draft.prompt,
          name: draft.name,
          member: draft.member);
      yield ToolResultEvent(ToolResult(
            callId: call.id,
            returnCode: 0,
            output: _triggerSetAnswer(stored),
          ));
    } catch (e) {
      yield ToolResultEvent(ToolResult(
            callId: call.id,
            returnCode: -1,
            output: "",
            exceptionInfo: "The trigger could not be set: $e",
          ));
    }
  }

  /// What registration says back: the id every later call speaks, and the
  /// source's own description — one wording of what was armed, shared with
  /// the settings row and the fire's reason rather than a second here.
  String _triggerSetAnswer(Trigger stored) =>
      "Trigger ${stored.id} set. "
      "${stored.member == null ? "" : "Fires addressed to @${stored.member}. "}"
      "${stored.source.describe()}."
      "${stored.source is FileSource ? " Fires only while the app is running." : ""}";

  /// Remove one of this chat's own triggers. Another chat's is not here to
  /// remove, and neither is a user-set one: the tools speak for the chat
  /// that registered their targets.
  Stream<AgentEvent> _triggerRemove(LlmToolCall call) async* {
    final registry = registerTrigger;
    final id = stringArg(call.argumentsJson, "id");
    if (id == null || registry == null) {
      yield* _reject(call,
          'The $triggerRemoveName tool takes {"id": "<trigger id>"}; that '
          "argument was missing.");
      return;
    }
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: id,
    ));
    final own = (await registry.own()).where((t) => t.id == id).toList();
    if (own.isEmpty) {
      yield ToolResultEvent(ToolResult(
            callId: call.id,
            returnCode: -1,
            output: "",
            exceptionInfo:
                "No trigger with that id was registered by this chat. "
                "$triggerListName lists what may be removed.",
          ));
      return;
    }
    await registry.remove(id);
    yield ToolResultEvent(ToolResult(
          callId: call.id,
          returnCode: 0,
          output: "Trigger $id removed.",
        ));
  }

  /// This chat's own triggers, with what each is waiting for.
  Stream<AgentEvent> _triggerList(LlmToolCall call) async* {
    final registry = registerTrigger;
    yield ToolCallEvent(
        ToolCall(id: call.id, name: call.name, argumentsJson: call.argumentsJson));
    final own = (await registry?.own() ?? []) ;
    if (own.isEmpty) {
      yield ToolResultEvent(ToolResult(
            callId: call.id,
            returnCode: 0,
            output: "No triggers registered for this chat.",
          ));
      return;
    }
    final lines = [
      for (final trigger in own)
        "- ${trigger.id}: ${trigger.name.isEmpty ? "(unnamed)" : trigger.name}"
            "${trigger.member == null ? "" : " → @${trigger.member}"}"
            " — ${trigger.source.describe()}"
            "${_whenLine(trigger)}",
    ];
    yield ToolResultEvent(ToolResult(
          callId: call.id,
          returnCode: 0,
          output: lines.join("\n"),
        ));
  }

  /// The stored fire time, worded for the answer — what is armed now, not
  /// the anchor a repeating source steps from, which goes stale as it fires
  /// and would tell the model its own trigger is overdue.
  String _whenLine(Trigger trigger) {
    final at = trigger.nextFireAt;
    return at == null ? "" : ". Next: ${_nextWording(at, trigger)}";
  }

  /// The source's own relative wording where it is on the clock ("in 30
  /// minutes", "Sat 22 Aug, daily" from the *next* occurrence), the plain
  /// moment otherwise. [describe] reads the anchor, so the schedule has to
  /// be re-worded here against the stored time.
  String _nextWording(DateTime at, Trigger trigger) {
    final source = trigger.source;
    return switch (source) {
      ScheduleSource(:final repeat) =>
        "${describeFire(at, DateTime.now())}"
            "${repeat == ScheduleRepeat.off ? "" : ", ${repeat.label.toLowerCase()}"}",
      _ => source.describe(),
    };
  }

  /// A fact the model judged worth keeping. No approval: like `websearch`, it
  /// reaches nothing and runs nothing — what it writes is a line in the app's
  /// own store, and a memory nobody wants is a line the user deletes in the
  /// explorer.
  Stream<AgentEvent> _memorySave(LlmToolCall call) async* {
    final text = stringArg(call.argumentsJson, "text");
    final store = memoryStore;
    if (text == null || store == null) {
      yield* _reject(call, 'The $memorySaveToolName tool takes {"text": "..."}; '
          "that argument was missing.");
      return;
    }
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: text,
    ));
    try {
      await store.add(text, chat: memoryChat);
    } catch (e) {
      yield ToolResultEvent(ToolResult(
            callId: call.id,
            returnCode: -1,
            output: "",
            exceptionInfo: "The memory could not be saved: $e",
          ));
      return;
    }
    yield ToolResultEvent(ToolResult(
          callId: call.id,
          returnCode: 0,
          output: "Memory saved. Later conversations are offered it when it "
              "looks relevant.",
        ));
  }

  /// Read-only over the app's own store, so no approval: it runs nothing and
  /// reaches nothing.
  Stream<AgentEvent> _memorySearch(LlmToolCall call) async* {
    final query = stringArg(call.argumentsJson, "query");
    final store = memoryStore;
    if (query == null || store == null) {
      yield* _reject(call, 'The $memorySearchToolName tool takes {"query": "..."}; '
          "that argument was missing.");
      return;
    }
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: query,
    ));
    final hits = await store.search(query);
    yield ToolResultEvent(ToolResult(
          callId: call.id,
          returnCode: 0,
          // The ids ride with the hits: they are the update and delete
          // tools' handles, and this is the only place the model sees them.
          output:
              hits.isEmpty ? "No memories match." : renderRecall(hits, withIds: true),
        ));
  }

  /// The correction half of the in-turn writing: the replacement stands where
  /// the old fact was, so a memory the user corrected is not left to drift
  /// beside its newer version.
  Stream<AgentEvent> _memoryUpdate(LlmToolCall call) async* {
    final id = stringArg(call.argumentsJson, "id");
    final text = stringArg(call.argumentsJson, "text");
    final store = memoryStore;
    if (id == null || text == null || store == null) {
      yield* _reject(call,
          'The $memoryUpdateToolName tool takes {"id": "...", "text": "..."}; '
          "that argument was missing.");
      return;
    }
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: text,
    ));
    try {
      await store.update(id, text, chat: memoryChat);
    } catch (e) {
      yield ToolResultEvent(ToolResult(
            callId: call.id,
            returnCode: -1,
            output: "",
            exceptionInfo: "The memory could not be updated: $e",
          ));
      return;
    }
    yield ToolResultEvent(ToolResult(
          callId: call.id,
          returnCode: 0,
          output: "Memory updated. The replacement stands where the old fact "
              "was.",
        ));
  }

  /// The half that costs a line in the log, not a new one: a fact the model
  /// judged wrong or spent, so a later recall does not carry it.
  Stream<AgentEvent> _memoryDelete(LlmToolCall call) async* {
    final id = stringArg(call.argumentsJson, "id");
    final store = memoryStore;
    if (id == null || store == null) {
      yield* _reject(call,
          'The $memoryDeleteToolName tool takes {"id": "..."}; that argument '
          "was missing.");
      return;
    }
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
    ));
    try {
      await store.delete(id);
    } catch (e) {
      yield ToolResultEvent(ToolResult(
            callId: call.id,
            returnCode: -1,
            output: "",
            exceptionInfo: "The memory could not be deleted: $e",
          ));
      return;
    }
    yield ToolResultEvent(ToolResult(
          callId: call.id,
          returnCode: 0,
          output: "Memory deleted, where it named an existing one.",
        ));
  }

  /// Publish an artifact from a workspace path. Copies the dir (or the file's
  /// parent) into the chat's `artifacts/` dir. A path the workspaces hold
  /// runs without asking; one that reaches past them is offered to the user
  /// first, since publishing is what makes the file's bytes part of the chat.
  Stream<AgentEvent> _artifact(LlmToolCall call) async* {
    final parsed = artifactArgsFrom(call.argumentsJson);
    if (parsed == null) {
      yield* _reject(call,
          'The $artifactToolName tool takes {"path": "..."}; that argument was missing.');
      return;
    }
    final path = _resolvePath(parsed.path);
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: parsed.title.isEmpty ? parsed.path : parsed.title,
    ));
    String? artifactId;
    Future<ShellResult> run() => _guarded(() async {
          artifactId = await saveArtifact!(
              parsed.path, parsed.entryFile,
              artifactId: parsed.artifactId);
          return const ShellResult(returnCode: 0, output: "");
        });
    if (outsideWorkspaces(fs, path, workspace, projectWorkspace)) {
      yield* _runGated(call, call.argumentsJson, artifactToolName, run,
          argumentsText: path);
    } else {
      _commandResult = await run();
    }
    final id = artifactId;
    if (_commandResult!.returnCode != 0 || id == null) {
      yield ToolResultEvent(_ran(call, _commandResult!));
      return;
    }
    yield ArtifactEvent(artifactId: id, entryFile: parsed.entryFile, title: parsed.title);
    final label = parsed.title.isEmpty ? parsed.path : "'${parsed.title}'";
    // One output, so the model is told how to update it on a reload too — the
    // instructions used to be said to the model alone and were lost with the
    // session.
    yield ToolResultEvent(_ran(
        call,
        const ShellResult(returnCode: 0, output: "")).copyWith(
        output: "Artifact $label published. The user can view it in the app. "
            "It is saved with the chat. To update it, edit the files and call "
            "artifact again with artifact_id: \"$artifactId\"."));
  }

  /// Package a skill the model drafted in its workspace and offer it to the
  /// user to install. Mirrors [_artifact]: the model writes files, calls the
  /// tool, and a card appears in the chat. The user reviews and installs from
  /// the card — the model cannot install it itself.
  Stream<AgentEvent> _createSkill(LlmToolCall call) async* {
    final args = createSkillArgsFrom(call.argumentsJson);
    if (args == null) {
      yield* _reject(call, createSkillFormatError);
      return;
    }
    final path = _resolvePath(args.path);
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: args.path,
    ));
    String? installId;
    String? skillName;
    Future<ShellResult> run() => _guarded(() async {
          final skillDir = fs.directory(path);
          if (!await skillDir.exists()) {
            return ShellResult.failed(
                "The directory '$path' does not exist. Write the skill there first "
                "with write/edit, then call $createSkillToolName.");
          }
          final skillMdPath = fs.path.join(path, "SKILL.md");
          if (!await fs.file(skillMdPath).exists()) {
            return ShellResult.failed(
                "The directory '$path' has no SKILL.md. A skill needs one.");
          }
          try {
            final result = await packageSkill!(args.path, args.name);
            installId = result.installId;
            skillName = result.name;
          } on SkillImportException catch (e) {
            return ShellResult.failed(
                "SKILL.md does not conform to the Agent Skills spec: $e. "
                "Fix the frontmatter and call $createSkillToolName again.");
          }
          return const ShellResult(returnCode: 0, output: "");
        });
    if (outsideWorkspaces(fs, path, workspace, projectWorkspace)) {
      yield* _runGated(call, call.argumentsJson, createSkillToolName, run,
          argumentsText: path);
    } else {
      _commandResult = await run();
    }
    final id = installId;
    if (_commandResult!.returnCode != 0 || id == null) {
      yield ToolResultEvent(_ran(call, _commandResult!));
      return;
    }
    final name = skillName ?? args.name ?? args.path;
    yield SkillInstallEvent(installId: id, title: name);
    yield ToolResultEvent(ToolResult(
          callId: call.id,
          returnCode: 0,
          output: "Skill '$name' packaged. "
              "The user can review and install it from the card below.",
        ));
  }

  /// The plan file: where the model works, so the model can read it and edit
  /// it around the tools. Resolved like a file-tool path but written through
  /// `fs` directly — the tools own the plan's lines, and an `edit` against
  /// them would be two writers on one file.
  String get _planPath => fs.path.join(workspace, planFileName);

  Future<String?> _readPlan() async {
    final file = fs.file(_planPath);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  /// What a plan tool says when there is nothing to work from, or null where
  /// the file is there with tasks in it.
  String? _planMissing(String? plan) {
    if (plan == null) {
      return "There is no $planFileName in the workspace yet. Record the "
          "first task with $planAddToolName.";
    }
    return planTasksFrom(plan).isEmpty
        ? "$planFileName holds no tasks. Add them with $planAddToolName."
        : null;
  }

  /// Record a task. The call is reported with the task as its text, so the
  /// chat's label reads the plan growing.
  Stream<AgentEvent> _planAdd(LlmToolCall call) async* {
    final task = stringArg(call.argumentsJson, "task");
    if (task == null) {
      yield* _reject(call,
          'The $planAddToolName tool takes {"task": "..."}; that argument '
          "was missing.");
      return;
    }
    final section = stringArg(call.argumentsJson, "section");
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: task,
    ));
    Future<ShellResult> run() async {
      final updated = planAddTask(await _readPlan(), task, section: section);
      await fs.file(_planPath).writeAsString(updated);
      return ShellResult(returnCode: 0, output: planAddResult(task, planProgress(updated)));
    }
    yield* _runFileTool(call, _planPath, planAddToolName, run);
  }

  /// Take the next task. Nothing to take is the answer, not a failure: the
  /// plan being finished is exactly the moment the model calls present_plan.
  Stream<AgentEvent> _planNext(LlmToolCall call) async* {
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
    ));
    final plan = await _readPlan();
    final missing = _planMissing(plan);
    final next = planNext(plan);
    if (next == null) {
      yield ToolResultEvent(ToolResult(
            callId: call.id,
            returnCode: 0,
            output: missing ?? "All tasks done.",
          ));
      return;
    }
    // The index came from the text just read, so the mark cannot miss.
    final marked = planMark(plan, next.index, PlanTaskStatus.inProgress)!;
    await fs.file(_planPath).writeAsString(marked);
    yield ToolResultEvent(ToolResult(
          callId: call.id,
          returnCode: 0,
          output: planNextResult(next, planProgress(marked)),
        ));
  }

  /// Finish a task: by number or by enough of its text to identify it.
  Stream<AgentEvent> _planDone(LlmToolCall call) async* {
    final task = stringArg(call.argumentsJson, "task");
    if (task == null) {
      yield* _reject(call,
          'The $planDoneToolName tool takes {"task": "..."} — the number '
          "$planNextToolName reported, or the start of the task's text; that "
          "argument was missing.");
      return;
    }
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: task,
    ));
    final plan = await _readPlan();
    final missing = _planMissing(plan);
    if (missing != null) {
      yield ToolResultEvent(_ran(call, ShellResult.failed(missing)));
      return;
    }
    final found = planFind(plan, task);
    if (found == null) {
      final candidates = planCandidates(plan, task)
          .map((t) => "${t.index}. ${t.text}")
          .toList();
      yield ToolResultEvent(_ran(
          call,
          ShellResult.failed(candidates.isEmpty
              ? "No task matches \"$task\". Call $planNextToolName to take "
                  "the next one, or read $planFileName."
              : "\"$task\" matches more than one task: ${candidates.join("; ")}. "
                  "Name it by number, or by more of its text.")));
      return;
    }
    // The index came from the text just read, so the mark cannot miss.
    final marked = planMark(plan, found.index, PlanTaskStatus.done)!;
    await fs.file(_planPath).writeAsString(marked);
    yield ToolResultEvent(ToolResult(
          callId: call.id,
          returnCode: 0,
          output: planDoneResult(found, planProgress(marked)),
        ));
  }

  /// The plan, put to the user: the plan's page published through the same
  /// path the `artifact` tool takes, its card in the chat, and the Go /
  /// changes question the panel asks — all one call, so the model cannot
  /// show the plan without asking about it, or ask without showing it.
  Stream<AgentEvent> _presentPlan(LlmToolCall call) async* {
    final args = presentPlanArgsFrom(call.argumentsJson);
    if (args == null) {
      yield* _reject(call,
          'The $presentPlanToolName tool takes no required arguments; "title" '
          'and "artifact_id" are optional strings.');
      return;
    }
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: args.title ?? planFileName,
    ));
    final plan = await _readPlan();
    final missing = _planMissing(plan);
    if (missing != null) {
      yield ToolResultEvent(_ran(call, ShellResult.failed(missing)));
      return;
    }
    final html = planHtml(plan!, title: args.title);
    final htmlPath = fs.path.join(workspace, planHtmlPath);
    final entryFile = fs.path.basename(planHtmlPath);
    await fs.directory(fs.path.dirname(htmlPath)).create(recursive: true);
    await fs.file(htmlPath).writeAsString(html);
    // Straight-line, so the publish's failure is the tool's answer rather
    // than the turn dying — the same answer `_guarded` would build, said
    // here because the plan's publish carries no approval gate around it.
    String? id;
    try {
      id = await saveArtifact!(planHtmlPath, entryFile,
          artifactId: args.artifactId);
    } catch (e) {
      yield ToolResultEvent(
          ToolResult(callId: call.id, returnCode: -1, output: "", exceptionInfo: "$e"));
      return;
    }
    yield ArtifactEvent(artifactId: id, entryFile: entryFile, title: args.title ?? "Plan");
    // Emitted before it is awaited, for the same reason an approval is: the
    // panel is where the verdict comes from. The verdict is then the tool's
    // result, so the model reads it as the outcome of presenting rather than
    // as the user's prose. The questions ride as the request's document —
    // what another device reads the call's arguments back out of — since the
    // call's own arguments name a title, not a question.
    final request = AskRequest(
      id: call.id,
      questions: [planApprovalQuestion(args.title)],
      argumentsJson: planApprovalQuestionsJson(args.title),
    );
    yield QuestionRequestEvent(request);
    final answers = await answer(request);
    yield ToolResultEvent(ToolResult(
          callId: call.id,
          returnCode: 0,
          output: planVerdict(answers.firstOrNull),
        ));
  }

  /// A call that could not be run at all: the UI still sees the pair, and the
  /// model still gets told why.
  Stream<AgentEvent> _reject(LlmToolCall call, String problem) async* {
    yield ToolCallEvent(
        ToolCall(id: call.id, name: call.name, argumentsJson: call.argumentsJson));
    yield ToolResultEvent(ToolResult(callId: call.id, returnCode: -1, output: "", exceptionInfo: problem));
  }

  /// Run [run] gated by the rules, then [approveMode]. Rules are the standing
  /// decision, so they are consulted first in every mode: an allow runs, a
  /// deny refuses without running or asking, an ask escalates — and no match
  /// falls through to what the mode answers. A banner answer granted mid-turn
  /// sits in front of the standing list.
  ///
  /// The rule's reach stops where the parse's does: a command with findings —
  /// one the static layer cannot model — is escalated to the banner even
  /// under an allow rule, never silently run. In `never` mode there is nobody
  /// to ask, so the findings refuse the command the way the veto always has.
  /// [argumentsText] is what the banner shows: what this call does, worded
  /// here where it is already in hand rather than parsed back out of the JSON
  /// by whoever draws it.
  Stream<AgentEvent> _runGated(
    LlmToolCall call,
    String arguments,
    String toolName,
    Future<ShellResult> Function() run, {
    String? argumentsText,
    ShellCommandAnalysis? analysis,
  }) async* {
    // A bash command is judged segment by segment: an allow that covers the
    // head but not the tail escalates the whole, so a compound command's
    // uncovered piece never rides a rule through. The parse is the one the
    // veto runs too — computed once here and handed down.
    analysis ??= toolName == "bash"
        ? ShellCommandAnalysis.parse(argumentsText ?? "",
            isWindows: platformIsWindows)
        : null;
    final rules = [..._runtimeRules, ...permissions];
    final verdict = rulesDecideTraced(
      rules,
      toolName,
      command: argumentsText,
      path: toolName == readToolName ||
              toolName == writeToolName ||
              toolName == editToolName
          ? argumentsText
          : null,
      url: toolName == webfetchToolName ? argumentsText : null,
      segments: analysis?.modelableSegments,
    );
    switch (verdict?.decision) {
      case PermissionDecision.deny:
        _decision = (
          source: PermissionSource.rule,
          tiers: verdict!.tiers,
          decided: PermissionDecision.deny,
        );
        _commandResult = const ShellResult.failed(
            "Denied by a permission rule you set. Do not retry this command; "
            "tell the user what you were trying to do and let them decide.");
        return;
      case PermissionDecision.allow:
        // An allow rule is a standing decision, but only for commands the
        // parse can vouch for: a compound command whose later segments the
        // rule does not cover runs with them unanswered. Findings here are a
        // banner, in every mode but never — where nobody is watching.
        final note = analysis?.escalationNote;
        if (note != null) {
          if (approveMode == ApproveMode.never) {
            _commandResult = ShellResult.failed(note);
            return;
          }
          yield* _askAndExecute(call, arguments, toolName, run, argumentsText);
          return;
        }
        _decision = (
          source: PermissionSource.rule,
          tiers: verdict!.tiers,
          decided: PermissionDecision.allow,
        );
        _commandResult = await run();
        return;
      case PermissionDecision.ask:
      case null:
        break;
    }
    // Where the rules left the command uncovered, the deterministic tiers
    // answer before any mode does: a segment the parse proves
    // non-modifying, a fetch the network rules allow, or a git mutation a
    // grant policy vouches for — every segment covered, or none is. An
    // "always show me" ask rule on any segment outranks the tier that would
    // cover it, the banner being what the user asked for there.
    if (toolName == "bash" && verdict == null && analysis != null) {
      final tiered = await _deterministicBashVerdict(analysis, rules);
      if (tiered != null) {
        _decision = (
          source: tiered.source,
          tiers: tiered.tiers,
          decided: tiered.decided,
        );
        if (tiered.decided == PermissionDecision.allow) {
          // Consumed by this command's run, where the sandbox carries the
          // grant the vouch was honest about; the re-run path and the
          // rule-covered ones recompute their own.
          _pendingGrantPaths = tiered.grantPaths;
          _commandResult = await run();
        } else {
          _commandResult = const ShellResult.failed(
              "Denied by a permission rule you set. Do not retry this "
              "command; tell the user what you were trying to do and let "
              "them decide.");
        }
        return;
      }
    }
    switch (approveMode) {
      case ApproveMode.ask:
        yield* _askAndExecute(call, arguments, toolName, run, argumentsText);
      case ApproveMode.auto:
        yield* _autoClassifyAndExecute(call, arguments, toolName, run, argumentsText);
      case ApproveMode.never:
        _decision = (
          source: PermissionSource.mode,
          tiers: const [],
          decided: PermissionDecision.allow,
        );
        _commandResult = await run();
    }
  }

  /// Run a file-touching tool behind the workspace gate: a path the workspaces
  /// hold runs straight, one that reaches past them is offered first. The
  /// three file tools share this tail — read, write and edit — differing only
  /// in their `run`; the artifact tool has its own, since it emits a second
  /// event on success.
  ///
  /// A throw inside [run] is the tool failing, not the turn: it is answered as
  /// a failed result the model reads, in the same shape every other tool
  /// failure takes, rather than escaping the stream as an error the turn dies
  /// on — a decode failure on a binary file used to end the turn.
  Stream<AgentEvent> _runFileTool(
    LlmToolCall call,
    String path,
    String toolName,
    Future<ShellResult> Function() run,
  ) async* {
    if (outsideWorkspaces(fs, path, workspace, projectWorkspace)) {
      yield* _runGated(call, call.argumentsJson, toolName,
          () => _guarded(run), argumentsText: path);
    } else {
      _commandResult = await _guarded(run);
    }
    yield ToolResultEvent(_ran(call, _commandResult!));
  }

  /// Answer what [run] throws as a failed result, so an unexpected failure —
  /// a decode, a full disk, a write that could not land — is one the model
  /// reads and works around rather than one that ends the turn.
  Future<ShellResult> _guarded(Future<ShellResult> Function() run) async {
    try {
      return await run();
    } catch (e) {
      return ShellResult.failed("$e");
    }
  }

  /// Emit the approval banner, wait for the user, and run [run] if allowed.
  /// Sets [_commandResult] to the outcome.
  Stream<AgentEvent> _askAndExecute(
    LlmToolCall call,
    String arguments,
    String toolName,
    Future<ShellResult> Function() run,
    String? argumentsText,
  ) async* {
    final approval = ToolApproval(
      id: call.id,
      toolName: toolName,
      argumentsJson: arguments,
      argumentsText: argumentsText,
    );
    yield ApprovalRequestEvent(approval);
    final answer = await approve(approval);
    // An "always" answer is the standing rule arriving: it applies to the
    // rest of this turn at once, ahead of the persisted copy the next turn
    // reads. The approval is in hand, so the derivation costs nothing here.
    // A re-prompt's approval carries what it agreed to: the denied dirs.
    if (approval.deniedDirs.isNotEmpty &&
        (answer == ApprovalResponse.alwaysAllowChat ||
            answer == ApprovalResponse.alwaysAllowProject)) {
      // The paths, not the prose: grant them for the turn; the repository
      // persists them to the tier the answer named.
      grantRuntimeDirs(approval.deniedDirs);
    } else if (answer == ApprovalResponse.alwaysAllowChat ||
        answer == ApprovalResponse.alwaysAllowProject) {
      final rule = ruleFromApproval(approval);
      if (rule != null) grantRuntimeRule(rule);
    }
    final allowed = answer == ApprovalResponse.allow ||
        answer == ApprovalResponse.alwaysAllowChat ||
        answer == ApprovalResponse.alwaysAllowProject;
    _decision = (
      source: PermissionSource.human,
      tiers: [
        switch (answer) {
          ApprovalResponse.alwaysAllowChat => PermissionTier.chat,
          ApprovalResponse.alwaysAllowProject => PermissionTier.project,
          _ => PermissionTier.once,
        },
      ],
      decided: allowed ? PermissionDecision.allow : PermissionDecision.deny,
    );
    _humanDecided = true;
    _commandResult = allowed
        ? await run()
        : const ShellResult.failed("The user denied this command. Ask them what to do "
            "instead, or try something else.");
    _humanDecided = false;
  }

  /// Classify the call, then allow (run), deny (refuse), or ask (escalate to
  /// the banner). Sets [_commandResult] to the outcome.
  Stream<AgentEvent> _autoClassifyAndExecute(
    LlmToolCall call,
    String arguments,
    String toolName,
    Future<ShellResult> Function() run,
    String? argumentsText,
  ) async* {
    if (_autoPaused) {
      yield* _askAndExecute(call, arguments, toolName, run, argumentsText);
      return;
    }

    final decision = await (classifier ?? const NoClassifier())
        .classify(toolName, arguments, workspace: workspace);

    if (decision != PermissionDecision.ask) {
      _consecutiveAsks = 0;
      _decision = (
        source: PermissionSource.classifier,
        tiers: const [],
        decided: decision,
      );
    }
    switch (decision) {
      case PermissionDecision.allow:
        _consecutiveAsks = 0;
        _commandResult = await run();
      case PermissionDecision.deny:
        _consecutiveAsks = 0;
        _commandResult = const ShellResult.failed(
            "Denied by auto mode as dangerous. Do not retry this command; "
            "tell the user what you were trying to do and let them decide.");
      case PermissionDecision.ask:
        _consecutiveAsks++;
        _totalAsks++;
        if (_consecutiveAsks >= 3 || _totalAsks >= 20) {
          _autoPaused = true;
          yield InfoEvent("Auto mode paused: too many uncertain commands. "
              "Asking for every command for the rest of this turn.");
        }
        yield* _askAndExecute(call, arguments, toolName, run, argumentsText);
    }
  }

  /// Whether the run this turn is composing sits behind an approval banner —
  /// a human reads the call and answers before it goes. Set by the arms that
  /// run after an approval, cleared by the arms that run without one: the
  /// static gate reads it to stand down, because a parse vetoing what a
  /// person approved is the machine overriding its keeper.
  bool _humanDecided = false;

  /// Directories the grant policy vouched for this call's command, read and
  /// cleared by the run — the sandbox carries them beside the workspaces,
  /// the fallback to recompute covering every path that reaches [_execute]
  /// without a tier decision ahead of it (rule allows, `never` mode, the
  /// re-run). Set only by the tier arm, cleared only here.
  List<String>? _pendingGrantPaths;

  Future<ShellResult> _execute(LlmToolCall call, String command,
      {bool unconfined = false, ShellCommandAnalysis? analysis}) async {
    if (_cancelled) {
      return const ShellResult.failed("The turn was stopped before this command ran.");
    }
    // The model's own bound for this command, capped at what the chat allows:
    // a small model's estimate of a build is as likely to be too short as too
    // long, and a cap is the only one that is never wrong.
    final args = decodeArgs(call.argumentsJson);
    final requested = intArg(call.argumentsJson, "timeout");
    final timeout = Duration(
      milliseconds: requested == null || requested <= 0
          ? options.commandTimeout.inMilliseconds
          : requested.clamp(0, options.commandTimeout.inMilliseconds),
    );
    // What the command parses to, decided before anything asks a model about
    // it. The parse answers for the deterministic safe side — reads, and
    // writes the workspace can hold — and refuses what it cannot answer for:
    // a command that cannot be modeled is one the model decided the wording
    // of, and one that assigns to a variable that rewrites where its own
    // writes land is not answering for itself.
    //
    // The gate is on only where a sandbox exists to make the boundary hold:
    // without one the parse has nothing to enforce, and refusing on its word
    // would be trusting the same text-only read the sandbox exists to back.
    // And it stands down where a person has decided: a run behind the
    // approval banner was read and answered by a human, and a parse vetoing
    // what the human approved is the machine overriding its keeper. The
    // banner, not the mode, is what carries that — auto mode reaches the
    // banner through the classifier's ask — so the gate reads the flag the
    // run itself sets.
    var sandbox = unconfined ? null : sandboxFor();
    final parsed = unconfined
        ? null
        : analysis ??
            (sandbox == null
                ? null
                : ShellCommandAnalysis.parse(
                    command, isWindows: platformIsWindows));
    if (sandbox != null && !_humanDecided) {
      final note = parsed!.escalationNote;
      if (note != null) {
        return ShellResult.failed(note);
      }
    }
    // The grant the tier vouched this command with, consumed here; every
    // path that arrives without one recomputes, the assessment being a pure
    // function of the same inputs the gate used.
    final vouched = _pendingGrantPaths;
    _pendingGrantPaths = null;
    if (sandbox != null) {
      final grantPaths = vouched ??
          [
            for (final grant
                in (await commandGrantsFor(
                        CommandGrantsInput(
                          fs: fs,
                          start:
                              shell.sessionCwdInHostWords(workspace) ??
                              workspace,
                          home: shell.machineHome,
                          segments: analysis!.modelableSegments ?? const [],
                        )))
                  .gitGrants
                  .values) ...grant.paths,
          ];
      if (grantPaths.isNotEmpty) {
        sandbox = sandbox.copyWith(extraWrites: [...sandbox.extraWrites, ...grantPaths]);
      }
    }
    final run = shell.start(command,
        cwd: workspace,
        home: projectWorkspace,
        timeout: timeout,
        environment: environment,
        oneShot: oneShot,
        restart: args?["restart"] == true,
        project: project,
        sandbox: sandbox);
    _running = run;
    _runWatched(call, run);
    try {
      return await run.result;
    } finally {
      _running = null;
    }
  }

  /// The deterministic bash tiers the rules leave standing: every segment
  /// covered by a rule allow, proven non-modifying by its own text, allowed
  /// by the network rules as a fetch, or vouched for by a grant policy with
  /// a grant the sandbox will carry. Null where any segment is uncovered,
  /// and where an ask rule wanted to see any of it — the mode's own path
  /// decides those, every time. A deny from the network rules is returned
  /// as one, refusal being what the rule said.
  Future<
      ({
        PermissionSource source,
        List<PermissionTier> tiers,
        PermissionDecision decided,
        List<String> grantPaths,
      })?> _deterministicBashVerdict(
    ShellCommandAnalysis analysis,
    List<PermissionRule> rules,
  ) async {
    final segments = analysis.modelableSegments;
    if (segments == null || segments.isEmpty) return null;
    // The host's own words for where the command runs: a guest's are the
    // only ones the shell's live report carries, and a walk of the machine
    // has no directory at that name to start from.
    final cwd = shell.sessionCwdInHostWords(workspace) ?? workspace;
    final grants = await commandGrantsFor(CommandGrantsInput(
        fs: fs, start: cwd, home: shell.machineHome, segments: segments));
    final tiers = <PermissionTier>{};
    var ruled = false;
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final profile = grants.profiles[i];
      if (!profile.modelable) return null;
      final segmentVerdict =
          rulesDecideTraced(rules, "bash", command: segment);
      switch (segmentVerdict?.decision) {
        case PermissionDecision.deny:
          return (
            source: PermissionSource.rule,
            tiers: segmentVerdict!.tiers.toList(),
            decided: PermissionDecision.deny,
            grantPaths: const <String>[],
          );
        case PermissionDecision.ask:
          return null;
        case PermissionDecision.allow:
          tiers.addAll(segmentVerdict!.tiers);
          ruled = true;
          continue;
        case null:
          break;
      }
      switch (profile.reach) {
        case SegmentReach.nonModifying:
          continue;
        case SegmentReach.network:
          // The same consult a `webfetch` call takes — one standing answer
          // covers the tool and the fetcher commands alike — with the
          // segment's host as the subject. A fetch whose host no rule speaks
          // for is uncovered, wherever the mode asks about it next.
          final network =
              rulesDecideTraced(rules, "webfetch", url: profile.url);
          switch (network?.decision) {
            case PermissionDecision.deny:
              return (
                source: PermissionSource.rule,
                tiers: network!.tiers.toList(),
                decided: PermissionDecision.deny,
                grantPaths: const <String>[],
              );
            case PermissionDecision.allow:
              tiers.addAll(network!.tiers);
              ruled = true;
              continue;
            case PermissionDecision.ask:
            case null:
              return null;
          }
        case SegmentReach.other:
          if (!grants.gitGrants.containsKey(i)) return null;
          continue;
      }
    }
    return (
      source: ruled ? PermissionSource.rule : PermissionSource.parse,
      tiers: ruled ? tiers.toList() : const <PermissionTier>[],
      decided: PermissionDecision.allow,
      grantPaths: [
        for (final grant in grants.gitGrants.values) ...grant.paths,
      ],
    );
  }

  /// After a command the confinement denied: one offer to rerun it, unconfined
  /// or with the denied directory joining the grant, rather than leaving the
  /// denial for the model to discover. Off under [sandboxReprompt] false, on a
  /// run a human already decided, in `never` mode — nobody is there to ask —
  /// and past the one per call this turn allows.
  ///
  /// Streaming, because the banner is where the answer comes from; the caller
  /// yields this between the first result and its report, and reads
  /// [_commandResult] after — set by the rerun, still the denial where none
  /// was asked for.
  Stream<AgentEvent> sandboxRepromptIfNeeded(
    LlmToolCall call,
    String command,
    ShellResult result,
  ) async* {
    if (result.violations.isEmpty ||
        !sandboxReprompt ||
        _humanDecided ||
        approveMode == ApproveMode.never) {
      return;
    }
    // The rerun rides the ordinary gated path — a denial the user denies here
    // is the answer, not a loop. _askAndExecute sets _humanDecided, so this
    // rerun's own result carries no second re-prompt, and its outcome is in
    // _commandResult when the events are done: the caller reads it there.
    // A write denial is rerun unconfined — the human read the command and
    // answered — and a read denial rerun confined, there being nothing a
    // grant could widen: a read refusal is the file's own perms.
    final writeDenied = result.violations.any((v) => v.startsWith("writing "));
    final deniedDirs = [
      for (final violation in result.violations)
        if (violation.startsWith("writing "))
          violation.substring("writing ".length),
    ];
    // The re-prompt's approval carries what it is agreeing to: the denied
    // directories. An "always" answer becomes a directory grant — runtime
    // for the turn here, persisted by the repository — never a command-prose
    // rule, which would match nothing next turn while claiming to.
    //
    // Its id is the call's own plus a suffix, deliberately not the call id:
    // the ask banner and this banner are two questions about one call, and
    // the approval plumbing keys by id — one completer, one view-state entry,
    // one removal. Sharing the id made the second banner inherit the first's
    // answer and vanish the moment the first was answered, which read as the
    // whole chain executing on a prompt that was never given.
    final approval = ToolApproval(
      id: "${call.id}-reprompt",
      toolName: "bash",
      argumentsJson: call.argumentsJson,
      argumentsText: result.violations.join("; "),
      deniedDirs: deniedDirs,
    );
    yield ApprovalRequestEvent(approval);
    final answer = await approve(approval);
    if (answer == ApprovalResponse.alwaysAllowChat ||
        answer == ApprovalResponse.alwaysAllowProject) {
      grantRuntimeDirs(deniedDirs);
    }
    final allowed = answer == ApprovalResponse.allow ||
        answer == ApprovalResponse.alwaysAllowChat ||
        answer == ApprovalResponse.alwaysAllowProject;
    _decision = (
      source: allowed ? PermissionSource.rerun : PermissionSource.human,
      tiers: allowed ? const [] : [PermissionTier.once],
      decided: allowed ? PermissionDecision.allow : PermissionDecision.deny,
    );
    _humanDecided = true;
    _commandResult = allowed
        ? await _execute(call, command, unconfined: writeDenied)
        : const ShellResult.failed("The user denied this command. Ask them what "
            "to do instead, or try something else.");
    _humanDecided = false;
  }

  /// Reports [run]'s output as it prints, each change no more than
  /// [watchInterval] apart. The watch holds the latest value rather than
  /// queueing reports behind a timer — what the block shows is the tail as it
  /// is now, not what it was — and the timer is cancelled with the result, so
  /// a command that finished inside an interval is not followed by a report of
  /// what it printed on the way out. Unsubscribed on the result, so the watch
  /// spans the whole run whatever awaits it.
  ///
  /// The one shape of it: the agent's own commands report through
  /// [onShellOutput], the user's `!` command through the same helper — the
  /// backend calls this with its own sink. Reading [run.output] is what tells
  /// the shell the run is watched; before that it pays nothing per chunk.
  static void watchShellOutput(
      ShellRun run, void Function(String text) report) {
    final output = run.output;
    if (output == null) return;
    Timer? timer;
    void listener() {
      timer ??= Timer(watchInterval, () {
        timer = null;
        final text = output.value;
        if (text != null && text.trim().isNotEmpty) report(text);
      });
    }

    output.addListener(listener);
    unawaited(run.result.whenComplete(() {
      timer?.cancel();
      output.removeListener(listener);
    }));
  }

  static const watchInterval = Duration(milliseconds: 100);

  void _runWatched(LlmToolCall call, ShellRun run) {
    if (onShellOutput == null) return;
    watchShellOutput(run, (text) => onShellOutput!(call.id, text));
  }

  /// Stream one model call, turning its chunks into events and leaving what it
  /// produced in [_completion] or [_queryError].
  ///
  /// A request that fails before it produced anything is tried again; one that
  /// fails halfway is reported, because retrying it would write the reply twice.
  ///
  /// A 429 takes a different path when a [rateLimitGate] is present: instead of
  /// the per-agent backoff below, every 429 advances the shared cooldown and
  /// every retry waits it out together — so a fan-out of sub-agents pauses as
  /// one rather than each-retry-into the same limit. 429 retries are bounded by
  /// the gate's wall-clock budget, not [BuiltinOptions.maxAttempts]; other
  /// retryables (503, connection drops) keep the per-agent path.
  Stream<AgentEvent> _query() async* {
    var attempt = 1;
    while (true) {
      var produced = false;
      var textStreamed = false;
      var reasoningClosed = false;
      DateTime? thinkingSince;
      String? signature;
      String? said;

      // Said before the request goes out, because that is where the wait
      // starts. On a hosted provider it is the whole of what can be known until
      // the first token; on a local one it is replaced by real progress within
      // a second.
      yield const StatusEvent("Thinking");

      try {
        await for (final chunk in client.stream(
          session.messages,
          model: model,
          tools: _tools,
          temperature: temperature,
          reasoningEffort: reasoningEffort,
        )) {
          if (_cancelled) return;
          switch (chunk) {
            case LlmPromptProgress():
              // Only llama.cpp sends these, and only while it is still reading
              // the prompt — so this never fires on a hosted provider and never
              // after the first token.
              //
              // Held and compared rather than forwarded: the server sends one
              // per batch, and the chat page rebuilds on every state change. A
              // percentage that has not moved is a redraw of the whole message
              // list for a row that would come out identical.
              final reading = readingPrompt(chunk);
              if (reading != said) {
                said = reading;
                yield StatusEvent(reading);
              }

            case LlmReasoningChunk(:final text):
              produced = true;
              // The thinking block itself says the rest from here.
              if (thinkingSince == null) yield const StatusEvent(null);
              thinkingSince ??= DateTime.now();
              yield ReasoningDelta(text);

            case LlmReasoningSignature():
              signature = chunk.signature;

            case LlmTextChunk(:final text):
              produced = true;
              // The caret says it from here.
              if (!textStreamed) yield const StatusEvent(null);
              textStreamed = true;
              // Thinking ended when the reply started, not when the call did.
              if (thinkingSince != null) {
                yield ReasoningEnd(
                    duration: DateTime.now().difference(thinkingSince),
                    signature: signature);
                thinkingSince = null;
                reasoningClosed = true;
              }
              yield TextDelta(text);

            case LlmCompletion():
              signature ??= chunk.message.reasoningSignature;
              if (thinkingSince != null) {
                yield ReasoningEnd(
                    duration: DateTime.now().difference(thinkingSince),
                    signature: signature);
                reasoningClosed = true;
              } else if (!reasoningClosed && chunk.message.reasoning != null) {
                // A provider that reports thinking only once it is over still
                // fills the block. Guarded, because the OpenAI shape reports it
                // *as well as* streaming it: closing the block a second time
                // writes the thinking twice, into the chat and into what goes
                // back to the provider.
                yield ReasoningEnd(text: chunk.message.reasoning, signature: signature);
              }
              // Text that was in the completion but never streamed as a delta —
              // the fake client does this, and a provider may too. Without it,
              // a no-tool-call reply that arrived unstreamed would end the turn
              // with the bubble showing nothing.
              if (!textStreamed && chunk.message.text.isNotEmpty) {
                yield TextDelta(chunk.message.text);
              }
              rateLimitGate?.onSuccess();
              _completion = chunk;
              if (chunk.usage != null && onUsage != null) {
                onUsage!(chunk.usage!);
              }
              return;
          }
        }
        if (_cancelled) return;
        // The stream ended without a completion: nothing was said and nothing
        // failed, which is a stall rather than a reply.
        throw const LlmException("The provider closed the stream without a reply.",
            retryable: true);
      } on LlmException catch (e) {
        // A request that produced chunks is not retried — the reply would be
        // written twice. Report it; the provider did serve it, so the gate
        // resets.
        if (produced) {
          rateLimitGate?.onSuccess();
          _queryError = e;
          return;
        }
        if (!e.retryable) {
          _queryError = e;
          return;
        }

        // 429 — coordinated cooldown. One gate across the parent and every
        // sub-agent: every 429 advances it, every retry waits it out.
        if (e.statusCode == 429 && rateLimitGate != null) {
          final gate = rateLimitGate!;
          if (gate.retryBudgetExhausted()) {
            _queryError = e;
            return;
          }
          gate.onRateLimited();
          yield RetryEvent(attempt: attempt, message: e.toString());
          await gate.awaitReady();
          // The wall-clock budget governs 429s; don't burn maxAttempts on them.
          attempt++;
          continue;
        }

        // Other retryables — per-agent backoff, maxAttempts unchanged.
        if (attempt >= options.maxAttempts) {
          _queryError = e;
          return;
        }
        yield RetryEvent(attempt: attempt, message: e.toString());
        await Future<void>.delayed(options.retryBackoff * (1 << (attempt - 1)));
        attempt++;
      } catch (e) {
        _queryError = e;
        return;
      }
    }
  }

  String? _commandOf(LlmToolCall call) => stringArg(call.argumentsJson, "command");
}
