import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:fs_shim/fs.dart";
import "package:flutter/foundation.dart" show visibleForTesting;
import "package:uuid/uuid.dart";

import "../../domain/agent_backend.dart";
import "../../domain/agent_browser.dart";
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
import "browser_tools.dart";
import "artifact_tool.dart";
import "compact_prompt.dart" show estimateTokens;
import "file_tools.dart" as file_tool_defs;
import "image_tool.dart";
import "llm/llm_client.dart";
import "llm/rate_limit_gate.dart";
import "../prompts/skill_import.dart" show SkillImportException;
import "participants_tool.dart";
import "skill_create_tool.dart";
import "skill_tool.dart";
import "sub_agent.dart";
import "task_tool.dart";
import "trigger_tool.dart";
import "customization_tools.dart";
import "../../domain/trigger.dart";
import "../../domain/trigger_manager.dart" show TriggerRegistry;
import "projection.dart";
import "templates.dart";
import "memory/instructions.dart";
import "memory/store.dart";
import "directory_tools.dart";
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
      browserGotoToolName || browserSearchToolName => "Opening a page",
      browserPageTextToolName => "Reading the page",
      browserScreenshotToolName => "Taking a screenshot",
      browserShowToolName => "Opening the browser window",
      browserCredentialsPromptToolName => "Waiting for you to sign in",
      browserCredentialsHideToolName => "Waiting for you to hand the browser back",
      taskToolName => "Working on a sub-task",
      triggerSetName => "Setting a trigger",
      artifactToolName => "Publishing the artifact",
      imageGenerationToolName => "Generating an image",
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

  BuiltinOptions copyWith({int? stepLimit, int? maxAttempts}) => BuiltinOptions(
        stepLimit: stepLimit ?? this.stepLimit,
        commandTimeout: commandTimeout,
        maxAttempts: maxAttempts ?? this.maxAttempts,
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
  void replaceWith(Iterable<LlmMessage> conversation) {
    messages
      ..clear()
      ..addAll(conversation);
    readFiles.clear();
  }

  /// The files the model has read, by resolved path, as they stood when it
  /// read them: what `write` and `edit` check an existing file against. Not
  /// rebuilt from the log — a session refilled after a rewind or a restart
  /// starts empty, and the model reads again.
  final Map<String, FileStamp> readFiles = {};

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
  bool offerImage = false,
  bool browserScreenshot = false,
  bool browserShow = false,
  bool oneShot = false,
  List<PromptDocument>? participants,
  bool member = false,
  bool customizing = false,
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
      // The room's roster: an omada turn only, non-null being the one gate
      // the tool list and the dispatch share — a call where the turn holds
      // no room finds only `unknownTool`.
      if (participants != null) listParticipantsTool,
      if (participants != null && member) endTurnTool,
      if (caps.artifact) artifactTool,
      if (!oneShot) ...[planAddTool, planNextTool, planDoneTool],
      // Presenting parks the turn on the panel's answer, so it rides `ask`:
      // a headless turn's and a sub-agent's takes fold it out of caps.
      if (caps.presentPlan) presentPlanTool,
      if (caps.createSkill) createSkillTool,
      // Triggers ride the turn itself: only a top-level turn is its own
      // chat's, so only it may register.
      if (caps.trigger && !oneShot) ...triggerToolDefs,
      if (customizing) ...[setProfileTool, setToneTool],
      if (offerMemory)
        ...[
          memorySaveTool,
          memorySearchTool,
          memoryUpdateTool,
          memoryDeleteTool,
        ],
      // The directory grant: rides `ask` — a banner somebody answers — and
      // only a top-level turn is its own chat's to cover; a headless or
      // one-shot turn has neither. Listing what is granted is a read of
      // the turn's own state, offered wherever a command list is. At the
      // end of the list, both, so the list's older adjacencies stand.
      if (caps.ask && !oneShot) addDirectoryTool,
      writableDirectoriesTool,
      if (offerImage) imageGenerationTool,
      if (caps.browser && !oneShot)
        ...browserTools(
          screenshot: browserScreenshot,
          show: browserShow,
          // Both park the turn on the user, so they ride `ask` as
          // `present_plan` does: a headless turn has nobody to answer.
          credentials: caps.ask,
        ),
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
    this.roomParticipants,
    this.webSearch,
    this.browser,
    this.seesImages = true,
    this.browserHidden = false,
    this.profile,
    this.tone = Tone.none,
    this.citations = false,
    this.saveArtifact,
    this.generateImage,
    this.saveResource,
    this.packageSkill,
    this.registerTrigger,
    this.editSettings,
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
    this.dataDir,
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

  /// The app's own data directory — settings, secrets, chats. The one shape
  /// [addDirectoryTool] refuses outright: the data directory itself, or
  /// anything that contains it, would make the app's own data writable from
  /// inside the grant. Null only where the answer has nothing to name —
  /// a test that does not exercise the refusal — and nothing is held back then.
  final String? dataDir;

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

  /// The writable set this turn covers beside the workspaces — the standing
  /// grants the repository composed plus what a banner answer added mid-turn.
  /// One store, two readers: [sandboxFor] composes it into every command's
  /// confinement and the file tools' workspace gate reads the same list, so a
  /// granted directory carries the chat workspace's own permissions by
  /// command or by file tool alike.
  List<String> get _grantedDirs => [...writableDirs, ..._runtimeDirs];

  /// The confinement a command runs under, from the shell's driver. Read per
  /// turn rather than held: the driver is resolved per command in the shell,
  /// and the sandbox is only ever offered where the machine itself is the
  /// driver — a guest's rootfs is already the boundary, and Android's
  /// per-app sandbox is the OS's.
  ///
  /// The project's workspace is granted beside the chat's own: it is where
  /// work another conversation should find goes, and the file tools and
  /// `writable_directories` already treat it as writable.
  CommandSandbox? sandboxFor() {
    final helper = sandboxHelper ?? shell.driverSandboxHelper;
    if (helper == null) return null;
    final tmp = shell.tmpDirFor(workspace);
    return CommandSandbox(
      workspace: workspace,
      tmp: tmp,
      home: shell.machineHome,
      extraWrites: [
        if (projectWorkspace != workspace) projectWorkspace,
        ..._grantedDirs,
      ],
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

  /// The room's participants, as the project's library holds them — the
  /// members an omada room's say routes to. Non-null only on an omada turn:
  /// the room contract is what names handles, and non-null is the one gate
  /// the tool list and the dispatch share. A sub-agent gets none — workers
  /// do not address the room, and no omada turn fans out.
  final List<PromptDocument>? roomParticipants;

  /// Web search and fetch. Null where neither is reachable — a browser sees
  /// `UnavailableWebSearch` and the tools are dropped the way `bash` is when
  /// there is no shell.
  final WebSearch? webSearch;

  /// This chat's tab in the browser Settings > Agent Browser picked. Null
  /// where none is picked, and for a sub-agent: a fan-out of workers on one
  /// window would navigate each other's pages.
  final BrowserTab? browser;

  /// Whether the model reads images, which is what offers the browser's
  /// screenshot: one that cannot would be sent each one as nothing.
  final bool seesImages;

  /// Whether the browser runs with no window, which offers `browser_show`.
  final bool browserHidden;

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

  /// Asks the image model for [prompt]. Null withholds `image_generation`:
  /// the setting is off, or the agent is a sub-agent.
  final Future<List<LlmAttachment>> Function(String prompt)? generateImage;

  /// Saves bytes under the chat's `resources/` and returns the resource name.
  /// Null where nothing is shown — a sub-agent's images are dropped.
  final Future<String> Function(String filename, Uint8List bytes)? saveResource;

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

  /// What the customization tools write through, or null, which withholds
  /// them — as it does on a sub-agent.
  final SettingsEditor? editSettings;

  /// Whether this session has loaded [customizationSkill], the one gate the
  /// tool list and the dispatch share.
  bool get _customizing =>
      editSettings != null &&
      session.messages.any((m) => m.toolCalls.any((c) =>
          c.name == skillToolName &&
          stringArg(c.argumentsJson, "skill") == customizationSkill));

  /// [caps] with the platform's facts applied where [caps] cannot know them:
  /// a tool the device cannot run is not offered even if the turn was, and a
  /// sub-agent's missing [subAgentRunner] or [saveArtifact] withholds `task`
  /// and `artifact` the way [AgentCapabilities.unattended] does from the front.
  AgentCapabilities get _offered => AgentCapabilities(
        commands: caps.commands && shell.canRunCommands,
        webSearch: caps.webSearch && (webSearch?.available ?? false),
        ask: caps.ask,
        // A sub-agent's work is commands; with no shell it has none to do.
        task: caps.task && subAgentRunner != null && shell.canRunCommands,
        artifact: caps.artifact && saveArtifact != null,
        createSkill: caps.createSkill && packageSkill != null,
        trigger: caps.trigger && registerTrigger != null,
        browser: caps.browser && browser != null && !oneShot,
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
        offerImage: generateImage != null && saveResource != null,
        browserScreenshot: seesImages && saveResource != null,
        browserShow: browserHidden,
        oneShot: oneShot,
        participants: roomParticipants,
        member: viewer != null,
        customizing: _customizing,
      );

  bool _cancelled = false;
  final Completer<void> _stopped = Completer();

  /// Set by an `end_turn` call: the loop stops after the batch it was in.
  bool _ended = false;
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
    if (!_stopped.isCompleted) _stopped.complete();
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

  /// [turn]'s events, through a recorder on their way out, with the session's
  /// turn half rebuilt from them as they land. A `yield` suspends the loop
  /// until its consumer takes the event, so everything a step produced is a
  /// part before the next step builds its request.
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
          session.replaceTurn(from, assistantMessages(said.parts, files: _images));
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
      if (_cancelled || _ended) break;

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
    // Where `task` is not offered, a call to it is answered as an unknown tool.
    final fanOut = _offered.task;
    final taskCalls = [
      if (fanOut)
        for (final call in calls)
          if (call.name == taskToolName) call,
    ];

    // Run every non-`task` call in order first. A command before a fan-out
    // has to be done before the fan-out starts, and one after has to wait for
    // it — the alternative, interleaving, would race a sub-agent against a
    // command it might depend on.
    for (final call in calls) {
      if (fanOut && call.name == taskToolName) continue;
      // What decided an earlier call is that call's, read or not.
      _decision = null;
      if (_cancelled) {
        // The call as well as the answer: a result whose call is not in the
        // parts is a result the projection has nothing to pair it to.
        yield* _reject(call, notExecuted);
        continue;
      }

      final doing = runningTool(call.name);
      if (doing != null) yield StatusEvent(doing);

      final Stream<AgentEvent> Function(LlmToolCall)? tool = switch (call.name) {
        readToolName => _read,
        writeToolName => _write,
        editToolName => _edit,
        askToolName => _ask,
        skillToolName => _skill,
        listParticipantsToolName when roomParticipants != null =>
          _listParticipants,
        endTurnToolName when roomParticipants != null && viewer != null =>
          _endTurn,
        websearchToolName => _webSearch,
        webfetchToolName => _webFetch,
        browserGotoToolName ||
        browserSearchToolName ||
        browserClickToolName ||
        browserTypeToolName ||
        browserDragToolName ||
        browserScrollToolName ||
        browserBackToolName ||
        browserPageTextToolName ||
        browserShowToolName when _offered.browser =>
          _browser,
        browserScreenshotToolName
            when _offered.browser && seesImages && saveResource != null =>
          _browserScreenshot,
        browserCredentialsPromptToolName when _offered.browser && caps.ask =>
          _browserCredentials,
        browserCredentialsHideToolName when _offered.browser && caps.ask =>
          _browserHide,
        memorySaveToolName => _memorySave,
        memorySearchToolName => _memorySearch,
        memoryUpdateToolName => _memoryUpdate,
        memoryDeleteToolName => _memoryDelete,
        artifactToolName when saveArtifact != null => _artifact,
        imageGenerationToolName
            when generateImage != null && saveResource != null =>
          _generateImage,
        planAddToolName when !oneShot => _planAdd,
        planNextToolName when !oneShot => _planNext,
        planDoneToolName when !oneShot => _planDone,
        presentPlanToolName when _offered.presentPlan => _presentPlan,
        createSkillToolName when packageSkill != null => _createSkill,
        triggerSetName when registerTrigger != null => _triggerSet,
        triggerRemoveName when registerTrigger != null => _triggerRemove,
        triggerListName when registerTrigger != null => _triggerList,
        setProfileName when _customizing => _setProfile,
        setToneName when _customizing => _setTone,
        addDirectoryName when caps.ask && !oneShot => _addDirectory,
        writableDirectoriesName => _writableDirectories,
        bashToolName => _bash,
        _ => null,
      };
      yield* tool == null
          ? _reject(call, unknownTool(call.name, _tools.map((t) => t.name)))
          : tool(call);
    }

    if (taskCalls.isEmpty) return;
    if (_cancelled) {
      // Answer the task calls that never ran, so the next turn is not rejected
      // for missing results.
      for (final call in taskCalls) {
        yield* _reject(call, notStarted);
      }
      return;
    }
    yield* _executeTasks(taskCalls);
  }

  Stream<AgentEvent> _bash(LlmToolCall call) async* {
    final command = stringArg(call.argumentsJson, "command");
    if (command == null) {
      yield* _reject(
          call,
          "The bash tool takes {\"command\": \"...\"}; that argument was missing "
          "or was not valid JSON.");
      return;
    }
    // One parse carried the whole way: the rule gate reads its segments, the
    // deterministic tier its answer, and the run's confinement the grant the
    // tier vouched with.
    final analysis = ShellCommandAnalysis.parse(command,
        isWindows: platformIsWindows);
    yield _called(call, command);
    yield* _runGated(call, bashToolName,
        () => _execute(call, command, analysis: analysis),
        argumentsText: command, analysis: analysis);
    // A denied write is offered back once between the result and its report,
    // the rerun's outcome replacing the denial.
    yield* sandboxRepromptIfNeeded(call, command, _commandResult!);
    yield ToolResultEvent(_ran(call, _commandResult!));
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
      yield _called(calls[i],
          args == null ? null : "@${args.agent}: ${_truncate(args.prompt, 200)}");
    }

    final controller = StreamController<AgentEvent>();

    Future<void> runOne(int index) async {
      final call = calls[index];
      final args = parsed[index];
      if (_cancelled) {
        controller.add(_failed(call, turnStopped));
        return;
      }
      if (args == null) {
        controller.add(_failed(call,
            'The $taskToolName tool takes {"agent": "...", "prompt": "..."}.'));
        return;
      }
      final (:agent, :prompt) = args;
      controller.add(SubAgentStartEvent(
          id: call.id, agent: agent, prompt: _truncate(prompt, 80)));
      final result = await subAgentRunner!.run(agent, prompt, callId: call.id);
      controller.add(SubAgentEndEvent(id: call.id, failed: result.returnCode != 0));
      controller.add(ToolResultEvent(_ran(call, result)));
    }

    // A bounded fan-out: maxConcurrentSubAgents workers, each taking the next
    // call as it finishes one.
    var next = 0;
    Future<void> worker() async {
      while (next < calls.length) {
        await runOne(next++);
      }
    }

    final allDone = Future.wait([
      for (var w = 0; w < options.maxConcurrentSubAgents && w < calls.length; w++)
        worker(),
    ]).whenComplete(controller.close);
    yield* controller.stream;
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

    yield _called(call);
    final request = AskRequest(
        id: call.id,
        questions: questions,
        argumentsJson: call.argumentsJson);
    // Emitted before it is awaited, for the same reason an approval is: the
    // panel is where the answers come from.
    yield QuestionRequestEvent(request);
    final answers = askAnswers(questions, await answer(request));

    yield _ok(call, answers);
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
    yield _called(call, arguments.isEmpty ? name : "$name $arguments");

    final document = skills.where((s) => s.name == name).firstOrNull;
    if (document == null) {
      yield _failed(call, skillUnknown(name, [
        for (final skill in skills)
          if (skill.modelInvocable && !skill.isCallback) skill.name,
      ]));
      return;
    }
    // A callback's body is the user-facing note, never a procedure for the
    // model to read — the same reason composition refuses to expand it.
    if (!document.modelInvocable || document.isCallback) {
      yield _failed(call, skillReserved(name));
      return;
    }
    yield _ok(call, _skillOutput(document, arguments));
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

  /// The room's roster. Read-only and instant, like `skill` — the answer is
  /// what the project's library holds, and the tool takes no arguments.
  Stream<AgentEvent> _listParticipants(LlmToolCall call) async* {
    yield _called(call);
    yield _ok(call, participantsListing(roomParticipants!));
  }

  /// Say nothing. The call and its result stay on the log, where the reason
  /// is the record of why; the loop stops without asking the model again,
  /// since a follow-up step would be the reply the call declined to write.
  Stream<AgentEvent> _endTurn(LlmToolCall call) async* {
    _ended = true;
    yield _called(call);
    yield _ok(call, "Turn ended.");
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
    yield _called(call, query);
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
    yield _called(call, url);
    yield* _runGated(call, webfetchToolName,
        () => webSearch!.fetch(url),
        argumentsText: url);
    final result = _commandResult!;
    yield ToolResultEvent(_ran(call, _withBrowserHint(result)));
  }

  /// A fetch that met a wall a browser gets past: a refusal, a challenge, or
  /// a page that is nothing until its script runs. Pointed at the browser
  /// where this turn has one.
  ShellResult _withBrowserHint(ShellResult result) {
    if (!_offered.browser) return result;
    final text = "${result.output}\n${result.exceptionInfo ?? ""}";
    final walled = RegExp(r"HTTP (401|403|429|503)\b").hasMatch(text) ||
        result.output == "The page has no readable text content." ||
        RegExp(r"enable javascript|just a moment|verify you are human|captcha",
                caseSensitive: false)
            .hasMatch(text.length > 3000 ? text.substring(0, 3000) : text);
    if (!walled) return result;
    const hint = "\n\nThis page may need a real browser: try "
        "`$browserGotoToolName` with the same URL.";
    return result.returnCode == 0
        ? ShellResult(returnCode: 0, output: "${result.output}$hint")
        : ShellResult.failed("${result.exceptionInfo ?? result.output}$hint");
  }

  /// The browser tools but the screenshot. Opening a page is gated as a fetch
  /// of the same URL, by the same network rules; a click, a typed field or a
  /// drag as a command is, worded by what it acts on so the banner and the
  /// classifier read an element rather than a number. Moving about a page
  /// and reading it are not gated.
  Stream<AgentEvent> _browser(LlmToolCall call) async* {
    final tab = browser!;
    if (tab.hold.value != null) {
      yield* _reject(call, _noted(_hidden));
      return;
    }
    final args = decodeArgs(call.argumentsJson) ?? const {};
    int? ref() => args["ref"] is int ? args["ref"] as int : null;
    double? number(Object? value) => value is num ? value.toDouble() : null;
    ({double x, double y})? point(Object? value) {
      if (value is! Map) return null;
      final x = number(value["x"]), y = number(value["y"]);
      return x == null || y == null ? null : (x: x, y: y);
    }

    final Future<String> Function() run;
    String label;
    String? navigate;
    String? acting;
    switch (call.name) {
      case browserGotoToolName:
        final url = stringArg(call.argumentsJson, "url");
        if (url == null) {
          yield* _reject(call, 'The $browserGotoToolName tool takes {"url": "..."}.');
          return;
        }
        label = url;
        navigate = url;
        run = () => tab.goto(url);
      case browserSearchToolName:
        final query = stringArg(call.argumentsJson, "query");
        if (query == null) {
          yield* _reject(call, 'The $browserSearchToolName tool takes {"query": "..."}.');
          return;
        }
        label = query;
        run = () => tab.goto(
            Uri.https("duckduckgo.com", "/", {"q": query}).toString());
      case browserClickToolName:
        final at = ref();
        final x = number(args["x"]), y = number(args["y"]);
        if (at == null && (x == null || y == null)) {
          yield* _reject(call,
              'The $browserClickToolName tool takes {"ref": n} or {"x": n, "y": n}.');
          return;
        }
        label = at != null ? "[$at]" : "($x, $y)";
        acting = "click";
        run = () => tab.click(ref: at, x: x, y: y);
      case browserTypeToolName:
        final at = ref();
        final text = args["text"];
        if (at == null || text is! String) {
          yield* _reject(call,
              'The $browserTypeToolName tool takes {"ref": n, "text": "..."}.');
          return;
        }
        final submit = args["submit"] == true;
        label = "[$at] $text";
        acting = submit ? "type \"$text\" and press Enter in" : "type \"$text\" in";
        run = () => tab.type(at, text, submit: submit);
      case browserDragToolName:
        final from = point(args["from"]), to = point(args["to"]);
        if (from == null || to == null) {
          yield* _reject(call, 'The $browserDragToolName tool takes '
              '{"from": {"x": n, "y": n}, "to": {"x": n, "y": n}}.');
          return;
        }
        label = "(${from.x}, ${from.y}) → (${to.x}, ${to.y})";
        acting = "drag from";
        run = () => tab.drag(from, to);
      case browserScrollToolName:
        final up = args["direction"] == "up";
        label = up ? "up" : "down";
        run = () => tab.scroll(up: up);
      case browserBackToolName:
        label = "back";
        run = tab.back;
      case browserShowToolName:
        label = "window";
        run = () => tab.show();
      default:
        final offset = number(args["offset"])?.toInt() ?? 0;
        label = offset == 0 ? "page" : "from $offset";
        run = () => tab.pageText(offset: offset);
    }
    yield _called(call, label);

    Future<ShellResult> attempt() async {
      try {
        return ShellResult(returnCode: 0, output: await run());
      } catch (e) {
        return ShellResult.failed("$e");
      }
    }

    if (navigate != null) {
      yield* _runGated(call, webfetchToolName, attempt, argumentsText: navigate);
    } else if (acting != null) {
      final String target;
      try {
        target = call.name == browserDragToolName
            ? await tab.describeTarget(
                x: number((args["from"] as Map)["x"]),
                y: number((args["from"] as Map)["y"]))
            : await tab.describeTarget(
                ref: ref(), x: number(args["x"]), y: number(args["y"]));
      } catch (e) {
        yield _failed(call, "$e");
        return;
      }
      final described = "$acting $target";
      // The arguments the classifier reads: the element and the page, which
      // the model's own `{"ref": 12}` says nothing about.
      final gate = LlmToolCall(
          id: call.id,
          name: call.name,
          argumentsJson: jsonEncode({"action": described}));
      yield* _runGated(gate, call.name, attempt, argumentsText: described);
    } else {
      _commandResult = await attempt();
    }
    final result = _commandResult!;
    _commandResult = result.returnCode == 0
        ? ShellResult(returnCode: 0, output: _noted(result.output))
        : ShellResult.failed(_noted(result.exceptionInfo ?? result.output));
    yield ToolResultEvent(_ran(call, _commandResult!));
  }

  /// [text] under what happened in the browser that this agent did not do
  /// since its last browser call — the user's back and forward, their hiding
  /// and giving back, the browser quitting. A turn is never handed a
  /// message mid-flight, so the next browser result is where the agent
  /// hears of it, and the log keeps it there.
  String _noted(String text) {
    final notes = browser?.takeNotes() ?? const [];
    if (notes.isEmpty) return text;
    return "Since your last browser call:\n"
        "${notes.map((note) => "- $note").join("\n")}\n\n$text";
  }

  static const _hidden = "The user has hidden the browser from you to do "
      "something private in it, such as signing in. Do not retry yet: carry "
      "on with something else, or ask the user and wait for them to say they "
      "have handed it back.";

  /// Wait on [wait] until it completes or the turn is stopped, whichever
  /// is first; null where the stop came first.
  Future<T?> _untilStopped<T>(Future<T> wait) =>
      Future.any([wait, _stopped.future.then((_) => null)]);

  /// Ask the user to fill in a sign-in. What they type goes from the
  /// chat's panel to the tab and into the page; the model is told only that
  /// it was done, and what the page then shows — passwords and the filled
  /// fields redacted.
  Stream<AgentEvent> _browserCredentials(LlmToolCall call) async* {
    final tab = browser!;
    final args = decodeArgs(call.argumentsJson) ?? const {};
    final reason = stringArg(call.argumentsJson, "reason");
    final fields = [
      for (final field in (args["fields"] as List? ?? const []))
        if (field is Map && field["ref"] is int && field["label"] is String)
          CredentialField(
            ref: field["ref"] as int,
            label: field["label"] as String,
            secret: field["secret"] == true,
          ),
    ];
    if (reason == null || fields.isEmpty) {
      yield* _reject(call, 'The $browserCredentialsPromptToolName tool takes '
          '{"reason": "...", "fields": [{"ref": n, "label": "..."}], '
          '"submit": [{"ref": n}]}.');
      return;
    }
    if (tab.hold.value != null) {
      yield* _reject(call, _noted(_hidden));
      return;
    }
    final submit = [
      for (final click in (args["submit"] as List? ?? const []))
        if (click is Map)
          (
            ref: click["ref"] is int ? click["ref"] as int : null,
            x: (click["x"] as num?)?.toDouble(),
            y: (click["y"] as num?)?.toDouble(),
          ),
    ];
    yield _called(call, reason);
    final String? done;
    try {
      done = await _untilStopped(tab.requestCredentials(
          CredentialRequest(reason: reason, fields: fields, submit: submit)));
    } catch (e) {
      yield _failed(call, "$e");
      return;
    }
    if (done == null) {
      tab.cancelCredentials();
      yield _failed(call, notExecuted);
      return;
    }
    yield _ok(call, _noted(done));
  }

  /// Hand the browser to the user: every other browser tool refuses until
  /// they give it back, which is what this waits for.
  Stream<AgentEvent> _browserHide(LlmToolCall call) async* {
    final tab = browser!;
    final reason = stringArg(call.argumentsJson, "reason");
    if (reason == null) {
      yield* _reject(call,
          'The $browserCredentialsHideToolName tool takes {"reason": "..."}.');
      return;
    }
    yield _called(call, reason);
    if (tab.hold.value == null) tab.hide(BrowserHold(reason: reason));
    final back = Completer<bool>();
    void given() {
      if (tab.hold.value == null && !back.isCompleted) back.complete(true);
    }

    tab.hold.addListener(given);
    try {
      given();
      if (await _untilStopped(back.future) == null) {
        // Stopped: the browser stays the user's until they give it back.
        yield _failed(call, notExecuted);
        return;
      }
    } finally {
      tab.hold.removeListener(given);
    }
    yield _ok(
        call,
        // The giving back is the note's to say.
        _noted("Read the page again before acting on it: the user may have "
            "moved on from where you left it."));
  }

  /// The viewport or one element, shown to the model on the result and to
  /// the user in the chat, as a generated image is.
  Stream<AgentEvent> _browserScreenshot(LlmToolCall call) async* {
    final ref = intArg(call.argumentsJson, "ref");
    if (browser!.hold.value != null) {
      yield* _reject(call, _noted(_hidden));
      return;
    }
    yield _called(call, ref == null ? "viewport" : "[$ref]");
    final BrowserShot shot;
    final ImageEvent saved;
    try {
      shot = await browser!.screenshot(ref: ref);
      saved = await _saved(LlmAttachment(
          filename: "screenshot.png", mimeType: "image/png", bytes: shot.png));
    } catch (e) {
      yield _failed(call, "$e");
      return;
    }
    yield saved;
    yield _ok(
        call,
        _noted(ref == null
            ? "Screenshot of the viewport attached."
            : "Screenshot of [$ref] attached. Its top-left corner is at "
                "(${shot.left.round()}, ${shot.top.round()}) in the viewport: "
                "add that to a point in it to click there."));
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
    yield _called(call, args.path);
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
      await _stamp(path);
      nested = memory.nested
          ? [
              // An AGENTS.md read on purpose is already in front of the model.
              for (final file in await findNestedInstructions(
                fs,
                path,
                alreadyLoaded: _loadedInstructions,
                excludes: memory.excludes,
              ))
                if (file.path != path) file,
            ]
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
    // Asked before the gate too, so a refusal raises no banner first.
    if (await _unread(path, args.path, writeToolName) case final problem?) {
      yield* _reject(call, problem);
      return;
    }
    yield _called(call, args.path);
    Future<ShellResult> run() async {
      if (await _unread(path, args.path, writeToolName) case final problem?) {
        return ShellResult.failed(problem);
      }
      await fs.directory(fs.path.dirname(path)).create(recursive: true);
      await fs.file(path).writeAsString(args.content);
      await _stamp(path);
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
    if (await _unread(path, args.path, editToolName) case final problem?) {
      yield* _reject(call, problem);
      return;
    }
    yield _called(call, args.path);
    Future<ShellResult> run() async {
      final file = fs.file(path);
      if (!await file.exists()) {
        return ShellResult(
            returnCode: -1, output: "", exceptionInfo: "File not found: ${args.path}");
      }
      if (await _unread(path, args.path, editToolName) case final problem?) {
        return ShellResult.failed(problem);
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
      await _stamp(path);
      return ShellResult(
          returnCode: 0, output: "Edited ${args.path}: replaced $count occurrence(s).");
    }
    yield* _runFileTool(call, path, editToolName, run);
  }

  Future<String?> _unread(String path, String shownPath, String toolName) =>
      unreadFileProblem(fs, path,
          shownPath: shownPath, toolName: toolName, readFiles: session.readFiles);

  /// What the model wrote is what it has seen, so the next edit needs no read.
  Future<void> _stamp(String path) async {
    final stamp = await fileStampOf(fs, path);
    if (stamp != null) session.readFiles[path] = stamp;
  }

  /// Register a trigger. The chat is the turn's own — a trigger fires into
  /// the conversation that registered it — and the registration is watched
  /// the moment the list lands. The model is told what it armed and when.
  Stream<AgentEvent> _triggerSet(LlmToolCall call) async* {
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
    yield _called(call, label);
    try {
      final stored = await registerTrigger!.register(
          source: draft.source,
          prompt: draft.prompt,
          name: draft.name,
          member: draft.member);
      yield _ok(call, _triggerSetAnswer(stored));
    } catch (e) {
      yield _failed(call, "The trigger could not be set: $e");
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
    final registry = registerTrigger!;
    final id = stringArg(call.argumentsJson, "id");
    if (id == null) {
      yield* _reject(call,
          'The $triggerRemoveName tool takes {"id": "<trigger id>"}; that '
          "argument was missing.");
      return;
    }
    yield _called(call, id);
    final own = (await registry.own()).where((t) => t.id == id).toList();
    if (own.isEmpty) {
      yield _failed(call, "No trigger with that id was registered by this chat. "
                "$triggerListName lists what may be removed.");
      return;
    }
    await registry.remove(id);
    yield _ok(call, "Trigger $id removed.");
  }

  Stream<AgentEvent> _setProfile(LlmToolCall call) async* {
    yield _called(call);
    String? error;
    await editSettings!((s) {
      final edited = editedProfile(s.profile, call.argumentsJson);
      error = edited.error;
      if (error == null) s.profile = edited.profile;
    });
    yield error == null ? _ok(call, "Profile saved.") : _failed(call, error!);
  }

  Stream<AgentEvent> _setTone(LlmToolCall call) async* {
    final tone = toneArg(call.argumentsJson);
    if (tone == null) {
      yield* _reject(call, 'The $setToneName tool takes {"tone": '
          '"default" | "direct" | "kind" | "formal"}.');
      return;
    }
    yield _called(call, tone.label);
    await editSettings!((s) => s.tone = tone);
    yield _ok(call, "Tone set to ${tone.label}.");
  }

  /// This chat's own triggers, with what each is waiting for.
  Stream<AgentEvent> _triggerList(LlmToolCall call) async* {
    yield _called(call);
    final own = await registerTrigger!.own();
    if (own.isEmpty) {
      yield _ok(call, "No triggers registered for this chat.");
      return;
    }
    final lines = [
      for (final trigger in own)
        "- ${trigger.id}: ${trigger.name.isEmpty ? "(unnamed)" : trigger.name}"
            "${trigger.member == null ? "" : " → @${trigger.member}"}"
            " — ${trigger.source.describe()}"
            "${_whenLine(trigger)}",
    ];
    yield _ok(call, lines.join("\n"));
  }

  /// The directory grant request. The banner is the whole grant: the model
  /// names a directory, the user answers on the ordinary approval banner,
  /// and the answer rides the plumbing the sandbox re-prompt already rides —
  /// [ToolApproval.deniedDirs] carries the directory, so an "always" answer
  /// lands in the named tier's `writableDirs` in `ChatRepository
  /// .respondApproval` with no branch of its own, and the rest of this turn
  /// is covered by [grantRuntimeDirs].
  ///
  /// Three shapes refuse before any banner: the app's own data tree — the
  /// data directory, anything beneath it, or anything containing it, which
  /// would make the app's settings, secrets and chats writable from inside
  /// its own permit — a path that names nothing, and a file where a
  /// directory was asked for.
  Stream<AgentEvent> _addDirectory(LlmToolCall call) async* {
    final path = stringArg(call.argumentsJson, "path");
    if (path == null) {
      yield* _reject(
          call,
          'The $addDirectoryName tool takes {"path": "..."}; that argument '
          "was missing.");
      return;
    }
    yield _called(call, path);
    final resolved = _resolvePath(path);
    final type = await fs.type(resolved);
    if (type == FileSystemEntityType.notFound) {
      yield _failed(call, "Directory not found: $resolved. "
          "Create it first, then ask again.");
      return;
    }
    if (type != FileSystemEntityType.directory) {
      yield _failed(call, "$resolved is not a directory. The grant covers a "
          "directory and everything under it; ask again with the directory "
          "the work belongs in.");
      return;
    }
    if (!outsideWorkspaces(fs, resolved, workspace, projectWorkspace)) {
      yield _ok(call, "$resolved is inside the workspaces, and writes there "
          "are already allowed. Nothing was granted.");
      return;
    }
    // The tree either way — beneath it is the app's own data, containing it
    // hands those writes to the sandbox — answered after the workspaces,
    // whose directories live beneath this tree and need no grant.
    // shortcut: a symlink aliasing the data dir passes as its own name,
    // until fs_shim grows link resolution to chase one with.
    if (dataDir != null &&
        (pathInside(dataDir!, resolved) || pathInside(resolved, dataDir!))) {
      yield _failed(call, "$resolved holds this app's own data, or lies "
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
    final answer = await approve(approval);
    if (!answer.isAllow) {
      _decision = (
        source: PermissionSource.human,
        tiers: const [PermissionTier.once],
        decided: PermissionDecision.deny,
      );
      yield ToolResultEvent(_ran(
          call,
          ShellResult.failed(
              "Denied. Write access to $resolved was not granted; carry on "
              "with the task — writes in that folder keep raising the "
              "ordinary per-write approval. Do not call $addDirectoryName "
              "again this turn.")));
      return;
    }
    grantRuntimeDirs([resolved]);
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
    _decision = (
      source: PermissionSource.human,
      tiers: tiers,
      decided: PermissionDecision.allow,
    );
    yield ToolResultEvent(_ran(call, ShellResult(returnCode: 0, output: wording)));
  }

  /// `writable_directories` — the turn's writable set, named. The workspaces
  /// stand first, every write in them being free; what [addDirectoryName]
  /// granted, standing or mid-turn, after them — anything the workspaces
  /// already hold is left out of that half, for being no grant at all; and
  /// `~` is spelled out, since the tools and commands take that shorthand and
  /// the grants are recorded absolute.
  Stream<AgentEvent> _writableDirectories(LlmToolCall call) async* {
    yield _called(call);
    final dirs = [
      for (final dir in _grantedDirs.toSet())
        if (outsideWorkspaces(fs, dir, workspace, projectWorkspace)) dir,
    ]..sort();
    final home = shell.homeFor(projectWorkspace);
    final lines = [
      "Workspace: $workspace",
      "Project workspace: $projectWorkspace",
      if (dirs.isEmpty)
        "No directories beside the workspaces have been granted write access."
      else ...[
        "Also writable, granted beside the workspaces:",
        for (final dir in dirs) "- $dir",
      ],
      if (home != null) "~ is $home.",
    ];
    yield _ok(call, lines.join("\n"));
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
    yield _called(call, text);
    try {
      await store.add(text, chat: memoryChat);
    } catch (e) {
      yield _failed(call, "The memory could not be saved: $e");
      return;
    }
    yield _ok(call, "Memory saved. Later conversations are offered it when it "
              "looks relevant.");
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
    yield _called(call, query);
    final hits = await store.search(query);
    // The ids ride with the hits: they are the update and delete tools'
    // handles, and this is the only place the model sees them.
    yield _ok(call,
        hits.isEmpty ? "No memories match." : renderRecall(hits, withIds: true));
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
    yield _called(call, text);
    try {
      if (await store.update(id, text, chat: memoryChat) == null) {
        yield _failed(call, "The memory could not be updated: no memory with "
            "id $id. Search again for its current id.");
        return;
      }
    } catch (e) {
      yield _failed(call, "The memory could not be updated: $e");
      return;
    }
    yield _ok(call, "Memory updated. The replacement stands where the old fact "
              "was.");
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
    yield _called(call);
    try {
      await store.delete(id);
    } catch (e) {
      yield _failed(call, "The memory could not be deleted: $e");
      return;
    }
    yield _ok(call, "Memory deleted, where it named an existing one.");
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
    yield _called(call, parsed.title.isEmpty ? parsed.path : parsed.title);
    String? artifactId;
    yield* _gatedPath(call, path, artifactToolName, () async {
      artifactId = await saveArtifact!(parsed.path, parsed.entryFile,
          artifactId: parsed.artifactId);
      return const ShellResult(returnCode: 0, output: "");
    });
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
        ShellResult(
            returnCode: 0,
            output: "Artifact $label published. The user can view it in the "
                "app. It is saved with the chat. To update it, edit the files "
                "and call artifact again with artifact_id: \"$id\".")));
  }

  /// Generate an image and show it in the reply. Not gated: it touches neither
  /// the workspace nor the shell, and the setting is the user's consent.
  Stream<AgentEvent> _generateImage(LlmToolCall call) async* {
    final prompt = stringArg(call.argumentsJson, "prompt");
    if (prompt == null) {
      yield* _reject(call,
          'The $imageGenerationToolName tool takes {"prompt": "..."}.');
      return;
    }
    yield _called(call, prompt);
    final List<ImageEvent> saved;
    try {
      final images = await generateImage!(prompt);
      saved = [for (final image in images) await _saved(image)];
    } catch (e) {
      yield _failed(call, "$e");
      return;
    }
    if (saved.isEmpty) {
      yield _failed(call, "The image model returned no image.");
      return;
    }
    for (final event in saved) {
      yield event;
    }
    yield _ok(call, "Generated ${saved.length} image(s), attached below and "
        "shown to the user in the chat.");
  }

  /// Images saved this session, by resource: the bytes the projection hands
  /// back to the model on the result that made them, as a reload reads them.
  final _images = <String, LlmAttachment>{};

  Future<ImageEvent> _saved(LlmAttachment image) async {
    final resource = await saveResource!(image.filename, image.bytes);
    _images[resource] = image;
    return ImageEvent(FilePart(
        resource: resource, filename: image.filename, mimeType: image.mimeType));
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
    yield _called(call, args.path);
    String? installId;
    String? skillName;
    yield* _gatedPath(call, path, createSkillToolName, () async {
      if (!await fs.directory(path).exists()) {
        return ShellResult.failed(
            "The directory '$path' does not exist. Write the skill there first "
            "with write/edit, then call $createSkillToolName.");
      }
      if (!await fs.file(fs.path.join(path, "SKILL.md")).exists()) {
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
    final id = installId;
    if (_commandResult!.returnCode != 0 || id == null) {
      yield ToolResultEvent(_ran(call, _commandResult!));
      return;
    }
    final name = skillName ?? args.name ?? args.path;
    yield SkillInstallEvent(installId: id, title: name);
    yield _ok(call, "Skill '$name' packaged. "
              "The user can review and install it from the card below.");
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
    final details = stringArg(call.argumentsJson, "details");
    if (details == null) {
      yield* _reject(call,
          'The $planAddToolName tool takes {"task": "...", "details": "..."}; '
          "the details were missing. Write the plan for this task: how it "
          "will be done, what it touches, and how it will be verified.");
      return;
    }
    final section = stringArg(call.argumentsJson, "section");
    yield _called(call, task);
    Future<ShellResult> run() async {
      final updated = planAddTask(await _readPlan(), task,
          section: section, details: details);
      await fs.file(_planPath).writeAsString(updated);
      return ShellResult(returnCode: 0, output: planAddResult(task, planProgress(updated)));
    }
    yield* _runFileTool(call, _planPath, planAddToolName, run);
  }

  /// Take the next task. Nothing to take is the answer, not a failure: the
  /// plan being finished is exactly the moment the model calls present_plan.
  Stream<AgentEvent> _planNext(LlmToolCall call) async* {
    yield _called(call);
    final plan = await _readPlan();
    final missing = _planMissing(plan);
    final next = planNext(plan);
    if (next == null) {
      yield _ok(call, missing ?? "All tasks done.");
      return;
    }
    // The index came from the text just read, so the mark cannot miss.
    final marked = planMark(plan, next.index, PlanTaskStatus.inProgress)!;
    await fs.file(_planPath).writeAsString(marked);
    yield _ok(call, planNextResult(next, planProgress(marked)));
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
    yield _called(call, task);
    final plan = await _readPlan();
    final missing = _planMissing(plan);
    if (missing != null) {
      yield _failed(call, missing);
      return;
    }
    final found = planFind(plan, task);
    if (found == null) {
      final candidates = planCandidates(plan, task)
          .map((t) => "${t.index}. ${t.text}")
          .toList();
      yield _failed(
          call,
          candidates.isEmpty
              ? "No task matches \"$task\". Call $planNextToolName to take "
                  "the next one, or read $planFileName."
              : "\"$task\" matches more than one task: ${candidates.join("; ")}. "
                  "Name it by number, or by more of its text.");
      return;
    }
    // The index came from the text just read, so the mark cannot miss.
    final marked = planMark(plan, found.index, PlanTaskStatus.done)!;
    await fs.file(_planPath).writeAsString(marked);
    yield _ok(call, planDoneResult(found, planProgress(marked)));
  }

  /// The plan, put to the user: the chat draws the present_plan call as the
  /// plan itself, read off $planFileName, and the Go / changes question the
  /// panel asks sits under it — one call, so the model cannot show the plan
  /// without asking about it, or ask without showing it.
  Stream<AgentEvent> _presentPlan(LlmToolCall call) async* {
    final args = presentPlanArgsFrom(call.argumentsJson);
    if (args == null) {
      yield* _reject(call,
          'The $presentPlanToolName tool takes no required arguments; "title" '
          "is an optional string.");
      return;
    }
    yield _called(call, args.title ?? planFileName);
    final missing = _planMissing(await _readPlan());
    if (missing != null) {
      yield _failed(call, missing);
      return;
    }
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
    yield _ok(call, planVerdict(answers.firstOrNull));
  }

  /// A call that could not be run at all: the UI still sees the pair, and the
  /// model still gets told why.
  Stream<AgentEvent> _reject(LlmToolCall call, String problem) async* {
    yield _called(call);
    yield _failed(call, problem);
  }

  /// [call] as reported, with [text] as what the label shows of it.
  static ToolCallEvent _called(LlmToolCall call, [String? text]) =>
      ToolCallEvent(ToolCall(
        id: call.id,
        name: call.name,
        argumentsJson: call.argumentsJson,
        argumentsText: text,
      ));

  static ToolResultEvent _ok(LlmToolCall call, String output) =>
      ToolResultEvent(ToolResult(callId: call.id, returnCode: 0, output: output));

  static ToolResultEvent _failed(LlmToolCall call, String problem) =>
      ToolResultEvent(ToolResult(
          callId: call.id, returnCode: -1, output: "", exceptionInfo: problem));

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
  ///
  /// [analysis] is a bash command's parse, judged segment by segment: an allow
  /// that covers the head but not the tail escalates the whole.
  Stream<AgentEvent> _runGated(
    LlmToolCall call,
    String toolName,
    Future<ShellResult> Function() run, {
    String? argumentsText,
    ShellCommandAnalysis? analysis,
  }) async* {
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
        _commandResult = const ShellResult.failed(_deniedByRule);
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
          yield* _askAndExecute(call, toolName, run, argumentsText);
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
          // grant the policy warranted; the re-run path and the
          // rule-covered ones recompute their own.
          _pendingGrantPaths = tiered.grantPaths;
          _commandResult = await run();
        } else {
          _commandResult = const ShellResult.failed(_deniedByRule);
        }
        return;
      }
    }
    switch (approveMode) {
      case ApproveMode.ask:
        yield* _askAndExecute(call, toolName, run, argumentsText);
      case ApproveMode.auto:
        yield* _autoClassifyAndExecute(call, toolName, run, argumentsText);
      case ApproveMode.never:
        _decision = (
          source: PermissionSource.mode,
          tiers: const [],
          decided: PermissionDecision.allow,
        );
        _commandResult = await run();
    }
  }

  /// Run a file tool behind the workspace gate and report its result.
  Stream<AgentEvent> _runFileTool(
    LlmToolCall call,
    String path,
    String toolName,
    Future<ShellResult> Function() run,
  ) async* {
    yield* _gatedPath(call, path, toolName, run, granted: _grantedDirs);
    yield ToolResultEvent(_ran(call, _commandResult!));
  }

  /// Run [run] behind the workspace gate, into [_commandResult]: a path the
  /// workspaces (or [granted]) hold runs straight, one past them is gated.
  ///
  /// A throw inside [run] is the tool failing, not the turn: it is answered as
  /// a failed result the model reads — a decode failure on a binary file used
  /// to end the turn.
  Stream<AgentEvent> _gatedPath(
    LlmToolCall call,
    String path,
    String toolName,
    Future<ShellResult> Function() run, {
    List<String> granted = const [],
  }) async* {
    if (outsideWorkspaces(fs, path, workspace, projectWorkspace,
        granted: granted)) {
      yield* _runGated(call, toolName, () => _guarded(run),
          argumentsText: path);
    } else {
      _commandResult = await _guarded(run);
    }
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
    String toolName,
    Future<ShellResult> Function() run,
    String? argumentsText,
  ) async* {
    final approval = ToolApproval(
      id: call.id,
      toolName: toolName,
      argumentsJson: call.argumentsJson,
      argumentsText: argumentsText,
    );
    yield ApprovalRequestEvent(approval);
    final answer = await approve(approval);
    // An "always" answer is the standing rule arriving: it applies to the
    // rest of this turn at once, ahead of the persisted copy the next turn
    // reads.
    if (answer == ApprovalResponse.alwaysAllowChat ||
        answer == ApprovalResponse.alwaysAllowProject) {
      final rule = ruleFromApproval(approval);
      if (rule != null) grantRuntimeRule(rule);
    }
    final allowed = answer.isAllow;
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
    _commandResult =
        allowed ? await run() : const ShellResult.failed(_deniedByUser);
    _humanDecided = false;
  }

  static const _deniedByUser = "The user denied this command. Ask them what "
      "to do instead, or try something else.";

  static const _deniedByRule = "Denied by a permission rule you set. Do not "
      "retry this command; tell the user what you were trying to do and let "
      "them decide.";

  /// Classify the call, then allow (run), deny (refuse), or ask (escalate to
  /// the banner). Sets [_commandResult] to the outcome.
  Stream<AgentEvent> _autoClassifyAndExecute(
    LlmToolCall call,
    String toolName,
    Future<ShellResult> Function() run,
    String? argumentsText,
  ) async* {
    if (_autoPaused) {
      yield* _askAndExecute(call, toolName, run, argumentsText);
      return;
    }

    // Raced with a stop: a turn outliving its abort ran on into the next
    // turn, clearing its banner and rewriting the session under it.
    final decision = await Future.any([
      (classifier ?? const NoClassifier()).classify(toolName, call.argumentsJson,
          workspace: workspace,
          alsoWritable: [
            if (projectWorkspace != workspace) projectWorkspace,
            ..._grantedDirs,
          ]),
      _stopped.future.then((_) => PermissionDecision.ask),
    ]);
    if (_cancelled) {
      _commandResult = const ShellResult.failed(notExecuted);
      return;
    }

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
        _commandResult = await run();
      case PermissionDecision.deny:
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
        yield* _askAndExecute(call, toolName, run, argumentsText);
    }
  }

  /// Whether the run this turn is composing sits behind an approval banner —
  /// a human reads the call and answers before it goes. Set by the arms that
  /// run after an approval, cleared by the arms that run without one: the
  /// static gate reads it to stand down, because a parse vetoing what a
  /// person approved is the machine overriding its keeper.
  bool _humanDecided = false;

  /// Directories the grant policy warranted for this call's command, read
  /// and
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
                          segments: parsed!.modelableSegments ?? const [],
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

  /// After a command the confinement denied: one offer to rerun it
  /// unconfined, rather than leaving the denial for the model to discover.
  /// Every violation is a write the sandbox refused — the ruleset reads
  /// everywhere — so unconfined is the one rerun that can go differently.
  /// Off under [sandboxReprompt] false and in `never` mode, where nobody is
  /// there to ask. The rerun is not offered again: it runs unconfined.
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
        approveMode == ApproveMode.never) {
      return;
    }
    // What an "always" answer grants. A denial the shim could not name has
    // no path here, and its banner offers no "always".
    final deniedDirs = [
      for (final violation in result.violations)
        if (violation.startsWith("writing /"))
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
      rerun: true,
    );
    yield ApprovalRequestEvent(approval);
    final answer = await approve(approval);
    if (answer == ApprovalResponse.alwaysAllowChat ||
        answer == ApprovalResponse.alwaysAllowProject) {
      grantRuntimeDirs(deniedDirs);
    }
    final allowed = answer.isAllow;
    _decision = (
      source: allowed ? PermissionSource.rerun : PermissionSource.human,
      tiers: allowed ? const [] : [PermissionTier.once],
      decided: allowed ? PermissionDecision.allow : PermissionDecision.deny,
    );
    _commandResult = allowed
        ? await _execute(call, command, unconfined: true)
        : const ShellResult.failed(_deniedByUser);
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

  /// What the request [completion] answered held, its reply counted in the
  /// chat so the estimate covers what the provider's count does.
  ContextUsage _contextOf(LlmCompletion completion) {
    final system =
        session.messages.takeWhile((m) => m.role == LlmRole.system).toList();
    final profileTokens = profileSection(profile).length ~/ 4;
    final tools = [
      for (final t in _tools)
        {"name": t.name, "description": t.description, "schema": t.schema},
    ];
    return ContextUsage(
      system: estimateTokens(system) - profileTokens,
      tools: jsonEncode(tools).length ~/ 4,
      profile: profileTokens,
      chat: estimateTokens([...session.conversation, completion.message]),
      reported: completion.usage?.contextTokens,
    );
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
              // A model that answers with images (OpenRouter's image models).
              if (saveResource != null) {
                for (final image in chunk.message.attachments.where((a) => a.isImage)) {
                  yield await _saved(image);
                }
              }
              rateLimitGate?.onSuccess();
              _completion = chunk;
              if (chunk.usage != null && onUsage != null) {
                onUsage!(chunk.usage!);
              }
              yield ContextEvent(_contextOf(chunk));
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
}
