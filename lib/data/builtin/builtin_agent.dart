import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:fs_shim/fs.dart";
import "package:flutter/foundation.dart" show visibleForTesting;
import "package:uuid/uuid.dart";

import "../../domain/agent_backend.dart";
import "../../domain/agent_browser.dart";
import "../../domain/ask.dart";
import "../../domain/file_tools.dart";
import "../../domain/models.dart";
import "../../domain/permission.dart";
import "../../domain/profile.dart";
import "../../domain/prompt_library.dart";
import "../../domain/shell.dart";
import "../../domain/tone.dart";
import "../../domain/tool_arg.dart";
import "../../domain/trigger_manager.dart" show TriggerRegistry;
import "../../domain/turn_recorder.dart";
import "../../domain/web_search.dart";
import "approval_gate.dart";
import "background_jobs.dart";
import "compact_prompt.dart" show estimateTokens;
import "llm/llm_client.dart";
import "llm/rate_limit_gate.dart";
import "memory/instructions.dart";
import "memory/store.dart";
import "projection.dart";
import "sub_agent.dart";
import "templates.dart";
import "tools/agent_tool.dart";
import "tools/customization_tools.dart";
import "tools/registry.dart";
import "tools/skill_tool.dart" show skillToolName;
import "tools/turn.dart";

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
/// the warm-up that caches it cannot build two different strings: this
/// message is the whole of what the prefill's key is over, and an argument
/// added at one site and not the other leaves a warmed prefix no chat ever
/// sends. The live turn is [BuiltinAgent._setSystemPrompt]; the cache is
/// `createLocalPrefill`.
LlmMessage agentSystemMessage({
  required String platform,
  Profile? profile,
  Tone tone = Tone.none,
  bool citations = false,
  ToolOffer offer = const ToolOffer(),
}) =>
    LlmMessage(
      role: LlmRole.system,
      text: systemPrompt(
        platform: platform,
        profile: profile,
        tone: tone,
        citations: citations,
        offer: offer,
      ),
    );

/// The agent loop: ask the model, run the command it asked for, show it the
/// result, repeat until it says it is done.
///
/// The skeleton is mini-swe-agent's `DefaultAgent`, ported; the termination
/// protocol is deliberately not — see AGENTS.md, "The agent loop".
class BuiltinAgent implements Turn {
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
    this.approveMode,
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
    this.seesPdfs = false,
    this.attachmentsDir,
    this.readOnlyDirs = const [],
    this.browserApprove = ApproveMode.never,
    this.browserUploads = BrowserUploadPolicy.classifier,
    this.profile,
    this.tone = Tone.none,
    this.citations = false,
    this.saveArtifact,
    this.generateImage,
    this.saveResource,
    this.packageSkill,
    this.registerTrigger,
    this.backgroundJobs,
    this.editSettings,
    this.onShellOutput,
    this.onUsage,
    this.loadResource = noResources,
    this.steers,
    this.memory = MemorySettings.off,
    this.instructions = const [],
    this.recall = "",
    this.pinned = "",
    this.index = "",
    this.memoryStore,
    this.memoryChat,
    this.sandboxHelper,
    this.policy = noPolicy,
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
  @override
  final bool Function(String path)? claimInstruction;

  /// The sandbox helper a test hands in, where the shell is a fake with no
  /// driver behind it. The agent reads the real one through
  /// [Shell.driverSandboxHelper]; this is the test seam for it, which is why
  /// it is nullable and the real answer wins when both exist.
  @visibleForTesting
  final SandboxHelper? sandboxHelper;

  /// What the permission pages set, merged chat over project over app by
  /// the repository, read afresh at every gated call: a rule saved while the
  /// turn runs — a banner's "always" included — covers the next call.
  final PolicyReader policy;

  /// The app's own data directory — settings, secrets, chats. The one shape
  /// `add_directory` refuses outright: the data directory itself, or
  /// anything that contains it, would make the app's own data writable from
  /// inside the grant. Null only where the answer has nothing to name —
  /// a test that does not exercise the refusal — and nothing is held back then.
  @override
  final String? dataDir;

  final BuiltinSession session;

  final LlmClient client;

  @override
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

  /// What the user says to this turn while it runs, read between steps. Null
  /// for a sub-agent, which nobody talks to.
  final SteerInbox? steers;

  /// What this turn reads and remembers. Only the `nested` half is consulted
  /// here: the instructions block was loaded by the backend before the agent
  /// existed, and the rest of the subsystem is later work.
  @override
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
  /// tools off the list, through [offer].
  @override
  final MemoryStore? memoryStore;

  /// What a saved memory is stamped with: the chat that wrote it. Beside
  /// [memoryStore] or neither.
  @override
  final String? memoryChat;

  /// AGENTS.md paths already in front of the model, seeded from
  /// [instructions]. A nested file found on a read is added, so the same one
  /// is never injected twice into a turn.
  @override
  Set<String> get loadedInstructions =>
      _loadedInstructionPaths ??= {
        for (final file in instructions) file.path,
      };
  Set<String>? _loadedInstructionPaths;

  /// The filesystem the file tools (`read`/`write`/`edit`) and the artifact
  /// tool's path resolution operate on. The same one `AppConfig` holds, so it
  /// is `fileSystemIo` on desktop and Android, `fileSystemWeb` (IndexedDB) in
  /// a browser — and the file tools work everywhere, unlike `bash`.
  @override
  final FileSystem fs;

  /// The chat's own directory, and where the shell starts.
  @override
  final String workspace;

  /// The project's workspace: the one every chat in the project shares where
  /// one is shared, the chat's own where one is not, resolved by the caller.
  /// Not the working directory: what a turn puts here is what it means other
  /// chats to find.
  @override
  final String projectWorkspace;

  /// The project's own command variables, layered over the app-level ones by
  /// the shell. The app-level ones are the shell's to read on each command,
  /// for the reason they are settings; these travel here because they were
  /// resolved where the project was, which is the backend's.
  @override
  final Map<String, String> environment;

  final String model;
  @override
  final BuiltinOptions options;
  final double? temperature;
  final String? reasoningEffort;

  /// How the agent handles a command before it runs, where the turn keeps a
  /// mode of its own (a sub-agent's); null reads the chat's live from
  /// [policy], so a change lands at the next call.
  final ApproveMode? approveMode;

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
  @override
  final Future<List<String?>> Function(AskRequest request) answer;

  /// Spawns sub-agents for `task` calls. Null where the agent is itself a
  /// sub-agent: sub-agents do not spawn their own sub-agents.
  @override
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
  @override
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
  @override
  final WebSearch? webSearch;

  /// This chat's tab in the browser Settings > Agent Browser picked. Null
  /// where none is picked, and for a sub-agent: a fan-out of workers on one
  /// window would navigate each other's pages.
  @override
  final BrowserTab? browser;

  /// Whether the model reads images, which is what offers the browser's
  /// screenshot: one that cannot would be sent each one as nothing.
  @override
  final bool seesImages;

  /// Whether a PDF reaches the model as a document, which is what `read`
  /// answers one with.
  @override
  final bool seesPdfs;

  /// The chat's `resources/`, what the user attached and the tools saved, at
  /// the path every shell reaches it by. Read-only to the agent: a command
  /// gets it bound read-only, `write` and `edit` refuse it, `read` reads it
  /// unasked, and `attachment_save` is how a copy that can change is made.
  /// Null where the agent has none, a sub-agent.
  @override
  final String? attachmentsDir;

  /// What a command may read and must not write, every shell alike: the
  /// chat's attachments and the skills and agents directories. A guest binds and guards
  /// them; on the machine they are read-only on disk already.
  @override
  final List<String> readOnlyDirs;

  /// The mode the browser's navigation and actions are gated by, in place
  /// of [approveMode]: Settings > Agent Browser's own answer, since a turn
  /// asking at every click is no use and picking a browser is the consent.
  /// The standing rules still decide first, so a denied host stays denied.
  @override
  final ApproveMode browserApprove;

  /// Who picks what `browser_upload` sends — its own scope, apart from
  /// [browserApprove], since a file leaving the machine is a different
  /// question from a click: the user can take it from the agent alone.
  final BrowserUploadPolicy browserUploads;

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
  @override
  final Future<String> Function(String path, String entryFile,
      {String? artifactId})? saveArtifact;

  /// Asks the image model for [prompt]. Null withholds `image_generation`:
  /// the setting is off, or the agent is a sub-agent.
  @override
  final Future<List<LlmAttachment>> Function(String prompt)? generateImage;

  /// Saves bytes under the chat's `resources/` and returns the resource name.
  /// Null where nothing is shown — a sub-agent's images are dropped.
  final Future<String> Function(String filename, Uint8List bytes)? saveResource;

  /// Packages a skill drafted in the workspace and stages the `.skill` for the
  /// user to install. Null where the agent is a sub-agent: a worker does not
  /// offer skills for install. Returns the install id.
  @override
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
  @override
  final TriggerRegistry? registerTrigger;

  /// This chat's background jobs, or null, which withholds `bash`'s
  /// `background`: a sub-agent, or a shell that cannot leave a run going.
  @override
  final ChatJobs? backgroundJobs;

  /// What the customization tools write through, or null, which withholds
  /// them — as it does on a sub-agent.
  @override
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


  /// What this turn is offered: the one value the tool list, the dispatch
  /// and the system prompt are all read from, so the prompt cannot advertise
  /// a tool the list does not carry. Read per step: `customizing` turns on
  /// mid-turn, once the skill that offers it is loaded.
  ToolOffer get offer => ToolOffer(
        caps: _offered,
        skills: skills,
        memory: memoryStore != null,
        images: generateImage != null && saveResource != null,
        screenshots: seesImages && saveResource != null,
        uploads: browserUploads,
        trustedInput: browser?.trustedInput ?? true,
        oneShot: oneShot,
        sandboxed: gate.helper != null,
        background: backgroundJobs != null,
        participants: roomParticipants,
        member: viewer != null,
        customizing: _customizing,
        attachments: attachmentsDir != null,
      );

  /// What the model may call this step: worked out once at its head and read
  /// by the request, the context count and the dispatch alike.
  List<AgentTool> _tools = const [];

  @override
  late final ApprovalGate gate = ApprovalGate(
    policy: policy,
    approveMode: approveMode,
    classifier: classifier,
    approve: approve,
    fs: fs,
    workspace: workspace,
    projectWorkspace: projectWorkspace,
    shell: shell,
    resolvePath: resolvePath,
    cancelled: () => _cancelled,
    stopped: _stopped.future,
    sandboxHelper: sandboxHelper,
  );

  /// Resolve a file-tool path through the workspaces, the guest root and the
  /// shell's home, so every call site carries the translation without
  /// spelling it out.
  @override
  String resolvePath(String path) => resolveWorkspacePath(
      fs, path, workspace, projectWorkspace,
      guestRoot: shell.guestRoot, homePath: shell.homeFor(projectWorkspace));

  @override
  Map<String, FileStamp> get readFiles => session.readFiles;

  bool _cancelled = false;
  final Completer<void> _stopped = Completer();

  @override
  bool get cancelled => _cancelled;

  @override
  Future<T?> untilStopped<T>(Future<T> wait) =>
      Future.any([wait, _stopped.future.then((_) => null)]);

  /// Set by an `end_turn` call: the loop stops after the batch it was in.
  bool _ended = false;

  @override
  void endTurn() => _ended = true;

  ShellRun? _running;

  @override
  Future<ShellResult> track(LlmToolCall call, ShellRun run) async {
    _running = run;
    final report = onShellOutput;
    if (report != null) watchShellOutput(run, (text) => report(call.id, text));
    try {
      return await run.result;
    } finally {
      _running = null;
    }
  }

  /// One step's scratch: what the model call produced. Fields rather than
  /// out-parameters because an `async*` method has no return value of its own,
  /// and the turn is single-threaded.
  LlmCompletion? _completion;
  ({Object error, StackTrace? trace})? _queryError;

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
          session.replaceTurn(from,
              assistantMessages(said.parts,
                  files: _images, resourcesDir: attachmentsDir));
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
      // Only after a step that ran tools: before the first, the prompt has
      // just gone, and a reply that ran none ends the turn, leaving what was
      // said to be queued as a turn of its own.
      if (step > 0) yield* _steered();
      _sayWhatWasSaid();

      // One response per step, named before it starts: what streams out of it
      // is stamped with this, so the turn can be handed back to a provider a
      // response at a time.
      yield ResponseStart(const Uuid().v4());

      _completion = null;
      _queryError = null;
      _tools = offeredTools(offer);
      yield* _query();
      if (_cancelled) break;
      if (_queryError case (:final error, :final trace)?) {
        yield ErrorEvent("$error",
            retryable: error is LlmException && error.retryable,
            trace: trace?.toString());
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

  /// What the user said since the last step, recorded so the rebuild below
  /// words it; its images are loaded first, since the rebuild is synchronous.
  Stream<AgentEvent> _steered() async* {
    final said = steers?.take() ?? const <Message>[];
    if (said.isEmpty) return;
    final loaded =
        await Future.wait(said.map((s) => attachmentsOf(s, loadResource)));
    for (final images in loaded) {
      _images.addAll(images);
    }
    for (final s in said) {
      yield SteerEvent(s);
    }
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
        first: mayDress,
        viewer: viewer,
        load: loadResource,
        resourcesDir: attachmentsDir));
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
    final offer = this.offer;
    final turn = turnPrompt(
      workspace: workspace,
      projectWorkspace: projectWorkspace,
      agentPrompt: agentPrompt,
      instructions: renderInstructions(instructions),
      pinned: pinned,
      index: index,
      recall: recall,
      canRunCommands: offer.caps.commands,
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
        offer: offer,
      ),
      if (turn.isNotEmpty) LlmMessage(role: LlmRole.system, text: turn),
    ];
    final replacing =
        session.messages.takeWhile((m) => m.role == LlmRole.system).length;
    session.messages.replaceRange(0, replacing, head);
  }

  /// Every call the model made gets an answer, including the ones we never ran:
  /// a provider that sees a tool call with no result rejects the next turn —
  /// and a call to a tool this turn was not offered is answered as one that
  /// does not exist.
  ///
  /// A batched tool's calls — `task`'s, which the deep-research prompt fans
  /// out up to 75 at once — run together once every other call has, in
  /// order, so a `bash` before a `task` is done first and a `bash` after
  /// waits for the fan-out. The session messages are answered in the calls' original
  /// order regardless, so the tool results pair up.
  Stream<AgentEvent> _executeAll(List<LlmToolCall> calls) async* {
    final tools = {for (final tool in _tools) tool.name: tool};
    final batches = <AgentTool, List<LlmToolCall>>{};
    for (final call in calls) {
      final tool = tools[call.name];
      if (tool != null && tool.batched) {
        (batches[tool] ??= []).add(call);
        continue;
      }
      gate.nextCall();
      if (_cancelled) {
        // The call as well as the answer: a result whose call is not in the
        // parts is a result the projection has nothing to pair it to.
        yield* toolRejected(call, notExecuted);
        continue;
      }
      if (tool?.runningLabel case final label?) yield StatusEvent(label);
      final ran = tool == null
          ? toolRejected(call, unknownTool(call.name, tools.keys))
          : tool.run(call, this);
      final jobs = backgroundJobs;
      yield* jobs == null ? ran : _withJobNotes(jobs, call, ran);
    }
    for (final MapEntry(key: tool, value: batch) in batches.entries) {
      if (tool.runningLabel case final label?) yield StatusEvent(label);
      yield* tool.runAll(batch, this);
    }
  }

  /// [events] with how the background jobs that ended since the last call
  /// ended carried on [call]'s result: on the result, so a reload words it
  /// the same.
  Stream<AgentEvent> _withJobNotes(
      ChatJobs jobs, LlmToolCall call, Stream<AgentEvent> events) async* {
    await for (final event in events) {
      if (event is ToolResultEvent && event.result.callId == call.id) {
        final notes = jobs.takeNotes();
        if (notes.isNotEmpty) {
          yield ToolResultEvent(event.result.copyWith(notes: notes));
          continue;
        }
      }
      yield event;
    }
  }

  /// Images saved this session, by resource: the bytes the projection hands
  /// back to the model on the result that made them, as a reload reads them.
  final _images = <String, LlmAttachment>{};

  @override
  bool get savesResources => saveResource != null;

  @override
  Future<ImageEvent> saved(LlmAttachment image) async {
    final resource = await saveResource!(image.filename, image.bytes);
    _images[resource] = image;
    return ImageEvent(FilePart(
        resource: resource, filename: image.filename, mimeType: image.mimeType));
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
          tools: [for (final tool in _tools) tool.definition],
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
                  yield await saved(image);
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
          _queryError = (error: e, trace: null);
          return;
        }
        if (!e.retryable) {
          _queryError = (error: e, trace: null);
          return;
        }

        // 429 — coordinated cooldown. One gate across the parent and every
        // sub-agent: every 429 advances it, every retry waits it out.
        if (e.statusCode == 429 && rateLimitGate != null) {
          final gate = rateLimitGate!;
          if (gate.retryBudgetExhausted()) {
            _queryError = (error: e, trace: null);
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
          _queryError = (error: e, trace: null);
          return;
        }
        yield RetryEvent(attempt: attempt, message: e.toString());
        await Future<void>.delayed(options.retryBackoff * (1 << (attempt - 1)));
        attempt++;
      } catch (e, trace) {
        _queryError = (error: e, trace: trace);
        return;
      }
    }
  }}
