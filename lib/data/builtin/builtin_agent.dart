import "dart:async";

import "package:fs_shim/fs.dart";
import "package:uuid/uuid.dart";

import "../../domain/agent_backend.dart";
import "../../domain/artifact.dart";
import "../../domain/ask.dart";
import "../../domain/file_tools.dart";
import "../../domain/models.dart";
import "../../domain/permission.dart";
import "../../domain/profile.dart";
import "../../domain/shell.dart";
import "../../domain/tool_arg.dart";
import "../../domain/web_search.dart";
import "ask_tool.dart";
import "artifact_tool.dart";
import "file_tools.dart" as file_tool_defs;
import "llm/llm_client.dart";
import "llm/rate_limit_gate.dart";
import "sub_agent.dart";
import "task_tool.dart";
import "templates.dart";
import "websearch_tool.dart";

/// The only tool for doing anything to the machine. Everything else — reading
/// a file, editing it, running the tests — is a command.
const bashTool = LlmTool(
  name: "bash",
  description: "Execute a bash command in the workspace directory.",
  schema: {
    "type": "object",
    "properties": {
      "command": {"type": "string", "description": "The bash command to execute"},
    },
    "required": ["command"],
  },
);

class BuiltinOptions {
  const BuiltinOptions({
    this.stepLimit = 40,
    this.commandTimeout = const Duration(seconds: 60),
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
  /// spend 7s waiting in total. Deliberately short: the UI cannot show what it
  /// has not been told, so trouble is reported long before its patience runs
  /// out. Applies to retryables other than 429; a 429 is governed by the
  /// shared [RateLimitGate] and [rateLimitRetryBudget].
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
}

/// A chat's conversation as the model sees it. Held per chat and outliving a
/// turn, which is what makes the next prompt a continuation rather than a
/// fresh task.
class BuiltinSession {
  final List<LlmMessage> messages = [];

  bool get isFresh => messages.isEmpty;

  /// Put the conversation back into a session that does not have it — one
  /// rewound, or one belonging to a chat opened after a restart. `project` is
  /// what builds the argument, out of what `conv.jsonl` kept.
  void replaceWith(Iterable<LlmMessage> conversation) => messages
    ..clear()
    ..addAll(conversation);
}

/// The agent loop: ask the model, run the command it asked for, show it the
/// result, repeat until it says it is done.
///
/// The skeleton is mini-swe-agent's `DefaultAgent`, ported; the termination
/// protocol is deliberately not — see CLAUDE.md, "The agent loop".
class BuiltinAgent {
  BuiltinAgent({
    required this.session,
    required this.client,
    required this.shell,
    required this.fs,
    required this.workspace,
    required this.projectWorkspace,
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
    this.offerTaskTool = true,
    this.offerAskTool = true,
    this.webSearch,
    this.profile,
    this.saveArtifact,
  });

  final BuiltinSession session;
  final LlmClient client;
  final Shell shell;

  /// The filesystem the file tools (`read`/`write`/`edit`) and the artifact
  /// tool's path resolution operate on. The same one `AppConfig` holds, so it
  /// is `fileSystemIo` on desktop and Android, `fileSystemWeb` (IndexedDB) in
  /// a browser — and the file tools work everywhere, unlike `bash`.
  final FileSystem fs;

  /// The chat's own directory, and where every command runs.
  final String workspace;

  /// The one every chat in the project shares. Not the working directory:
  /// what a turn puts there is what it means other chats to find.
  final String projectWorkspace;

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

  /// Whether to offer the `task` tool. Sub-agents run headless and do not
  /// fan out themselves, so they pass `false`.
  final bool offerTaskTool;

  /// Whether to offer the `ask_user` tool. Sub-agents run unattended, so they
  /// pass `false`.
  final bool offerAskTool;

  /// Web search and fetch. Null where neither is reachable — a browser sees
  /// `UnavailableWebSearch` and the tools are dropped the way `bash` is when
  /// there is no shell.
  final WebSearch? webSearch;

  /// The user's profile, appended to the system prompt as "About the user".
  /// Null means nothing is added. Rewritten every turn with the rest of the
  /// system prompt.
  final Profile? profile;

  /// Publishes an artifact from a workspace path to the chat's `artifacts/`
  /// dir and returns the id. Null where the agent is a sub-agent: sub-agents run
  /// headless with no viewer surface, so the tool is dropped for them the way
  /// `ask_user` is. The closure resolves the path (with `project:` prefix
  /// support) and copies the dir; the agent just passes the args through.
  final Future<String> Function(String path, {String? artifactId})? saveArtifact;

  /// What the model may call. `bash` is dropped where nothing can run it —
  /// offering a tool we could only ever answer with a failure invites one.
  /// `task` is dropped where there is no [subAgentRunner] (a sub-agent) or
  /// where the shell is unavailable. `ask_user` is dropped for sub-agents.
  /// `websearch`/`webfetch` are dropped where there is no [webSearch] or it is
  /// unavailable (a browser). `artifact` is dropped where there is no
  /// [saveArtifact] (a sub-agent). `read`/`write`/`edit` are always offered —
  /// they work on the `FileSystem`, which exists on every platform.
  List<LlmTool> get _tools => [
        file_tool_defs.readTool,
        file_tool_defs.writeTool,
        file_tool_defs.editTool,
        if (shell.canRunCommands) bashTool,
        if (offerAskTool) askTool,
        if (offerTaskTool && subAgentRunner != null && shell.canRunCommands) taskTool,
        if (webSearch != null && webSearch!.available) ...[
          websearchTool,
          webfetchTool,
        ],
        if (saveArtifact != null) artifactTool,
      ];

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

  Stream<AgentEvent> run(
    String task, {
    List<LlmAttachment> attachments = const [],
    String? agentPrompt,
  }) async* {
    _openTurn(task, attachments, agentPrompt);
    yield* _loop();
  }

  /// [run] without the task: the session is already holding everything the
  /// interrupted turn had done, so all this adds is the reason it is being
  /// asked again.
  ///
  /// Not even that where the session ends in a user message, which is a turn
  /// killed before the model was ever called. Telling a model it was cut off
  /// part-way when there is nothing of its own above is a contradiction, and
  /// small models are what this app is for.
  Stream<AgentEvent> resume({String? agentPrompt}) async* {
    _setSystemPrompt(agentPrompt);
    if (session.messages.lastOrNull?.role != LlmRole.user) {
      session.messages.add(const LlmMessage(role: LlmRole.user, text: continueTask));
    }
    yield* _loop();
  }

  Stream<AgentEvent> _loop() async* {
    for (var step = 0; step < options.stepLimit; step++) {
      if (_cancelled) break;

      // One response per step, named before it starts: what streams out of it
      // is stamped with this, so the turn can be handed back to a provider a
      // response at a time.
      yield ResponseStart(const Uuid().v4());

      _completion = null;
      _queryError = null;
      yield* _query();
      if (_cancelled) break;
      if (_queryError != null) {
        yield ErrorEvent("$_queryError");
        break;
      }
      final completion = _completion;
      if (completion == null) break;

      session.messages.add(completion.message);

      // A reply with no tool calls is the finished answer — the text was
      // already streamed as TextDelta by _query. This is the native API
      // contract models are trained on, and works with or without a shell.
      if (completion.message.toolCalls.isEmpty) break;

      yield* _executeAll(completion.message.toolCalls);
      if (_cancelled) break;

      if (step == options.stepLimit - 1) {
        yield ErrorEvent("Stopped after ${options.stepLimit} steps without finishing. "
            "Ask again to carry on.");
      }
    }

    yield const DoneEvent();
  }

  void _openTurn(String task, List<LlmAttachment> attachments, String? agentPrompt) {
    final fresh = session.isFresh;
    _setSystemPrompt(agentPrompt);
    session.messages.add(LlmMessage(
      role: LlmRole.user,
      // Only the first prompt is dressed as a task; the rest continue it.
      text: fresh ? firstTask(task) : task,
      attachments: attachments,
    ));
  }

  /// The system prompt is rewritten every turn rather than once, so an
  /// `@agent` mention applies to the turn that used it whether or not the
  /// session is new — and so a resumed turn runs under the prompt the turn it
  /// is continuing ran under.
  void _setSystemPrompt(String? agentPrompt) {
    final system = LlmMessage(
      role: LlmRole.system,
      text: systemPrompt(
        workspace: workspace,
        projectWorkspace: projectWorkspace,
        platform: shell.platformDescription,
        agentPrompt: agentPrompt,
        profile: profile,
        canRunCommands: shell.canRunCommands,
      ),
    );
    if (session.messages.firstOrNull?.role == LlmRole.system) {
      session.messages[0] = system;
    } else {
      session.messages.insert(0, system);
    }
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
          _answerRun(call, const ShellResult.failed(notExecuted));
        }
        continue;
      }

      if (call.name == taskToolName) continue;

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

      if (call.name == websearchToolName) {
        yield* _webSearch(call);
        continue;
      }

      if (call.name == webfetchToolName) {
        yield* _webFetch(call);
        continue;
      }

      if (call.name == artifactToolName && saveArtifact != null) {
        yield* _artifact(call);
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

      yield ToolCallEvent(ToolCall(
        id: call.id,
        name: "bash",
        argumentsJson: call.argumentsJson,
        argumentsText: command,
      ));

      yield* _runGated(call, call.argumentsJson, "bash", () => _execute(command),
          argumentsText: command);
      final result = _commandResult!;

      yield ToolResultEvent(ToolResult(
        callId: call.id,
        returnCode: result.returnCode,
        output: result.output,
        exceptionInfo: result.exceptionInfo,
      ));

      _answerRun(call, result);
    }

    if (taskCalls.isEmpty || _cancelled) {
      // Answer the task calls that never ran, so the next turn is not rejected
      // for missing results.
      for (final call in taskCalls) {
        yield* _reject(call, "This sub-agent was not started.");
      }
      return;
    }

    yield* _executeTasks(taskCalls);
  }

  /// Run a batch of `task` calls concurrently, capped to
  /// [BuiltinOptions.maxConcurrentSubAgents]. Events stream as each sub-agent
  /// resolves; session messages are answered in the calls' original order so
  /// the tool results pair up with the calls.
  Stream<AgentEvent> _executeTasks(List<LlmToolCall> calls) async* {
    final results = List<ShellResult?>.filled(calls.length, null);
    final controller = StreamController<AgentEvent>();

    Future<void> runOne(int index) async {
      if (_cancelled) {
        results[index] = const ShellResult.failed("This sub-agent was not started.");
        return;
      }
      final call = calls[index];
      final parsed = _taskArgsOf(call);
      if (parsed == null) {
        controller.add(ToolCallEvent(
            ToolCall(id: call.id, name: call.name, argumentsJson: call.argumentsJson)));
        controller.add(ToolResultEvent(ToolResult(
            callId: call.id,
            returnCode: -1,
            output: "",
            exceptionInfo: 'The $taskToolName tool takes {"agent": "...", "prompt": "..."}.')));
        results[index] = const ShellResult.failed(
            'The task tool takes {"agent": "...", "prompt": "..."}.');
        return;
      }
      final (:agent, :prompt) = parsed;
      controller.add(SubAgentStartEvent(
          id: call.id, agent: agent, prompt: _truncate(prompt, 80)));
      final result = await subAgentRunner!.run(agent, prompt, callId: call.id);
      results[index] = result;
      controller.add(SubAgentEndEvent(id: call.id, failed: result.returnCode != 0));
      controller.add(ToolCallEvent(ToolCall(
          id: call.id,
          name: call.name,
          argumentsJson: call.argumentsJson,
          argumentsText: "@$agent: ${_truncate(prompt, 200)}")));
      controller.add(ToolResultEvent(ToolResult(
          callId: call.id,
          returnCode: result.returnCode,
          output: result.output,
          exceptionInfo: result.exceptionInfo)));
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
          results[i] = const ShellResult.failed("The turn was stopped.");
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

    // Answer each in the original order, so the session messages pair up.
    for (var i = 0; i < calls.length; i++) {
      final result = results[i];
      if (result == null) {
        _answerRun(calls[i], const ShellResult.failed("This sub-agent was not started."));
      } else {
        _answerRun(calls[i], result);
      }
    }
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

  /// Answer a call the model made. Every one gets exactly this, whether it ran
  /// or not — a provider that sees a tool call with no result rejects the next
  /// turn.
  void _answer(LlmToolCall call, String text) => session.messages
      .add(LlmMessage(role: LlmRole.tool, toolCallId: call.id, text: text));

  /// How a command's outcome is worded, which is every call but an `ask_user`:
  /// one that ran, one that was refused, one that was never reached.
  void _answerRun(LlmToolCall call, ShellResult result) => _answer(
        call,
        observation(
          returnCode: result.returnCode,
          output: result.output,
          exceptionInfo: result.exceptionInfo,
        ),
      );

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
    final request = AskRequest(id: call.id, questions: questions);
    // Emitted before it is awaited, for the same reason an approval is: the
    // panel is where the answers come from.
    yield QuestionRequestEvent(request);
    final answers = askAnswers(questions, await answer(request));

    yield ToolResultEvent(ToolResult(callId: call.id, returnCode: 0, output: answers));
    _answer(call, answers);
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
    yield ToolResultEvent(ToolResult(
      callId: call.id,
      returnCode: result.returnCode,
      output: result.output,
      exceptionInfo: result.exceptionInfo,
    ));
    _answerRun(call, result);
  }

  /// Fetch a URL. Read-only, so no approval.
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
    yield ToolResultEvent(ToolResult(
      callId: call.id,
      returnCode: result.returnCode,
      output: result.output,
      exceptionInfo: result.exceptionInfo,
    ));
    _answerRun(call, result);
  }

  /// Read a file from the workspace. No approval: the workspace is the
  /// agent's own dir, and `bash` already reads from it without a banner in
  /// `never` mode.
  Stream<AgentEvent> _read(LlmToolCall call) async* {
    final args = readArgsFrom(call.argumentsJson);
    if (args == null) {
      yield* _reject(call,
          'The $readToolName tool takes {"path": "..."}; that argument was missing.');
      return;
    }
    final resolved = resolveWorkspacePath(fs, args.path, workspace, projectWorkspace);
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: args.path,
    ));
    final file = fs.file(resolved);
    if (!await file.exists()) {
      yield ToolResultEvent(ToolResult(
        callId: call.id,
        returnCode: -1,
        output: "",
        exceptionInfo: "File not found: ${args.path}",
      ));
      _answer(call, "File not found: ${args.path}");
      return;
    }
    final content = await file.readAsString();
    final lines = content.split("\n");
    final offset = (args.offset ?? 1).clamp(1, lines.length + 1);
    final limit = args.limit ?? lines.length;
    final end = (offset + limit - 1).clamp(1, lines.length);
    final buf = StringBuffer();
    for (var i = offset; i <= end; i++) {
      buf.writeln("$i: ${lines[i - 1]}");
    }
    final result = buf.toString();
    yield ToolResultEvent(ToolResult(
      callId: call.id,
      returnCode: 0,
      output: result.isEmpty ? "(empty)" : result,
    ));
    _answer(call, result.isEmpty ? "(empty file)" : result);
  }

  /// Write a file to the workspace, creating or overwriting. No approval:
  /// the workspace is the agent's own dir.
  Stream<AgentEvent> _write(LlmToolCall call) async* {
    final args = writeArgsFrom(call.argumentsJson);
    if (args == null) {
      yield* _reject(call,
          'The $writeToolName tool takes {"path": "...", "content": "..."}; '
          "those arguments were missing.");
      return;
    }
    final resolved = resolveWorkspacePath(fs, args.path, workspace, projectWorkspace);
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: args.path,
    ));
    await fs.directory(fs.path.dirname(resolved)).create(recursive: true);
    await fs.file(resolved).writeAsString(args.content);
    final bytes = args.content.length;
    yield ToolResultEvent(ToolResult(
      callId: call.id,
      returnCode: 0,
      output: "Wrote $bytes bytes to ${args.path}",
    ));
    _answer(call, "Wrote $bytes bytes to ${args.path}");
  }

  /// Edit a file by exact string replacement. No approval: the workspace is
  /// the agent's own dir.
  Stream<AgentEvent> _edit(LlmToolCall call) async* {
    final args = editArgsFrom(call.argumentsJson);
    if (args == null) {
      yield* _reject(call,
          'The $editToolName tool takes {"path": "...", "old_string": "...", '
          '"new_string": "..."}; those arguments were missing.');
      return;
    }
    final resolved = resolveWorkspacePath(fs, args.path, workspace, projectWorkspace);
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: args.path,
    ));
    final file = fs.file(resolved);
    if (!await file.exists()) {
      yield ToolResultEvent(ToolResult(
        callId: call.id,
        returnCode: -1,
        output: "",
        exceptionInfo: "File not found: ${args.path}",
      ));
      _answer(call, "File not found: ${args.path}");
      return;
    }
    final content = await file.readAsString();
    final count = content.split(args.oldString).length - 1;
    if (count == 0) {
      yield ToolResultEvent(ToolResult(
        callId: call.id,
        returnCode: -1,
        output: "",
        exceptionInfo: "old_string not found in ${args.path}",
      ));
      _answer(call, "old_string not found in ${args.path}");
      return;
    }
    if (!args.replaceAll && count > 1) {
      yield ToolResultEvent(ToolResult(
        callId: call.id,
        returnCode: -1,
        output: "",
        exceptionInfo: "old_string appears $count times in ${args.path}; "
            "add context to make it unique or set replace_all.",
      ));
      _answer(call, "old_string appears $count times in ${args.path}; "
          "add context to make it unique or set replace_all.");
      return;
    }
    final updated = args.replaceAll
        ? content.replaceAll(args.oldString, args.newString)
        : content.replaceFirst(args.oldString, args.newString);
    await file.writeAsString(updated);
    yield ToolResultEvent(ToolResult(
      callId: call.id,
      returnCode: 0,
      output: "Edited ${args.path}: replaced $count occurrence(s).",
    ));
    _answer(call, "Edited ${args.path}: replaced $count occurrence(s).");
  }

  /// Publish an artifact from a workspace path. Copies the dir (or the file's
  /// parent) into the chat's `artifacts/` dir. No approval: like `websearch`,
  /// it reaches nothing and runs nothing.
  Stream<AgentEvent> _artifact(LlmToolCall call) async* {
    final parsed = artifactArgsFrom(call.argumentsJson);
    if (parsed == null) {
      yield* _reject(call,
          'The $artifactToolName tool takes {"path": "..."}; that argument was missing.');
      return;
    }
    yield ToolCallEvent(ToolCall(
      id: call.id,
      name: call.name,
      argumentsJson: call.argumentsJson,
      argumentsText: parsed.title.isEmpty ? parsed.path : parsed.title,
    ));
    final artifactId = await saveArtifact!(parsed.path, artifactId: parsed.artifactId);
    yield ArtifactEvent(artifactId: artifactId, entryFile: parsed.entryFile, title: parsed.title);
    final label = parsed.title.isEmpty ? parsed.path : "'${parsed.title}'";
    yield ToolResultEvent(ToolResult(
      callId: call.id,
      returnCode: 0,
      output: "Artifact $label published. The user can view it in the app. "
          "artifact_id: $artifactId",
    ));
    _answer(call,
        "Artifact published. The user can view it in the app. It is saved with "
        "the chat. To update it, edit the files and call artifact again with "
        "artifact_id: \"$artifactId\".");
  }

  /// A call that could not be run at all: the UI still sees the pair, and the
  /// model still gets told why.
  Stream<AgentEvent> _reject(LlmToolCall call, String problem) async* {
    yield ToolCallEvent(
        ToolCall(id: call.id, name: call.name, argumentsJson: call.argumentsJson));
    yield ToolResultEvent(
        ToolResult(callId: call.id, returnCode: -1, output: "", exceptionInfo: problem));
    _answerRun(call, ShellResult.failed(problem));
  }

  /// Run [run] gated by [approveMode]: ask the user, classify then maybe ask,
  /// or run directly. Emits the approval banner and circuit-breaker info as
  /// needed, and sets [_commandResult] to the outcome.
  /// [argumentsText] is what the banner shows: what this call does, worded
  /// here where it is already in hand rather than parsed back out of the JSON
  /// by whoever draws it.
  Stream<AgentEvent> _runGated(
    LlmToolCall call,
    String arguments,
    String toolName,
    Future<ShellResult> Function() run, {
    String? argumentsText,
  }) async* {
    switch (approveMode) {
      case ApproveMode.ask:
        yield* _askAndExecute(call, arguments, toolName, run, argumentsText);
      case ApproveMode.auto:
        yield* _autoClassifyAndExecute(call, arguments, toolName, run, argumentsText);
      case ApproveMode.never:
        _commandResult = await run();
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
    final allowed = await approve(approval) == ApprovalResponse.allow;
    _commandResult = allowed
        ? await run()
        : const ShellResult.failed("The user denied this command. Ask them what to do "
            "instead, or try something else.");
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

    switch (decision) {
      case PermissionDecision.allow:
        _consecutiveAsks = 0;
        _commandResult = await run();
      case PermissionDecision.deny:
        _consecutiveAsks = 0;
        _commandResult = const ShellResult.failed(
            "Denied by auto mode. The classifier flagged this as dangerous. "
            "Ask the user what to do instead.");
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

  Future<ShellResult> _execute(String command) async {
    if (_cancelled) {
      return const ShellResult.failed("The turn was stopped before this command ran.");
    }
    final run = shell.start(command, cwd: workspace, timeout: options.commandTimeout);
    _running = run;
    try {
      return await run.result;
    } finally {
      _running = null;
    }
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
            case LlmReasoningChunk(:final text):
              produced = true;
              thinkingSince ??= DateTime.now();
              yield ReasoningDelta(text);

            case LlmReasoningSignature():
              signature = chunk.signature;

            case LlmTextChunk(:final text):
              produced = true;
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
