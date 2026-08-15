import "dart:async";
import "dart:convert";

import "../../domain/agent_backend.dart";
import "../../domain/ask.dart";
import "../../domain/models.dart";
import "../../domain/shell.dart";
import "ask_tool.dart";
import "llm/llm_client.dart";
import "templates.dart";

/// The only tool mini-swe-agent gives a model. Everything else — reading a
/// file, editing it, running the tests — is a command.
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

class MinisweOptions {
  const MinisweOptions({
    this.stepLimit = 40,
    this.commandTimeout = const Duration(seconds: 60),
    this.maxConsecutiveFormatErrors = 3,
    this.maxAttempts = 4,
    this.retryBackoff = const Duration(seconds: 1),
  });

  /// How many model calls one turn may make. Upstream defaults to no limit and
  /// leans on a cost limit instead; a chat has someone waiting, so it counts
  /// steps.
  final int stepLimit;
  final Duration commandTimeout;
  final int maxConsecutiveFormatErrors;

  /// How many times a failed request is tried again before the turn gives up,
  /// and the first wait between two — it doubles after that, so the defaults
  /// spend 7s waiting in total. Deliberately short: the UI cannot show what it
  /// has not been told, so trouble is reported long before its patience runs
  /// out.
  final int maxAttempts;
  final Duration retryBackoff;
}

/// A chat's conversation as the model sees it. Held per chat and outliving a
/// turn, which is what makes the next prompt a continuation rather than a
/// fresh task.
class MinisweSession {
  final List<LlmMessage> messages = [];

  bool get isFresh => messages.isEmpty;

  void clear() => messages.clear();

  /// Seed a session that missed the conversation, so a rewound chat is not
  /// answered by a model that never saw it. Worded as an exchange because a
  /// bare preamble reads as the task itself.
  void seed(String transcript) {
    clear();
    if (transcript.isEmpty) return;
    messages.add(LlmMessage(role: LlmRole.user, text: transcriptPreamble(transcript)));
    messages.add(const LlmMessage(
      role: LlmRole.assistant,
      text: "Understood. I have the conversation so far.",
    ));
  }
}

/// mini-swe-agent's control flow, in Dart: ask the model, run the command it
/// asked for, show it the result, repeat until it says it is done.
class MinisweAgent {
  MinisweAgent({
    required this.session,
    required this.client,
    required this.shell,
    required this.workspace,
    required this.projectWorkspace,
    required this.model,
    required this.approve,
    required this.answer,
    this.options = const MinisweOptions(),
    this.requireApproval = true,
    this.temperature,
    this.reasoningEffort,
  });

  final MinisweSession session;
  final LlmClient client;
  final Shell shell;

  /// The chat's own directory, and where every command runs.
  final String workspace;

  /// The one every chat in the project shares. Not the working directory:
  /// what a turn puts there is what it means other chats to find.
  final String projectWorkspace;

  final String model;
  final MinisweOptions options;
  final double? temperature;
  final String? reasoningEffort;

  /// Whether to ask before running anything. Per turn rather than part of
  /// [options]: it is the chat's own setting, and it arrives with the prompt.
  final bool requireApproval;

  /// Asks the user whether a command may run. Only called when
  /// [requireApproval] is set.
  final Future<ApprovalResponse> Function(ToolApproval approval) approve;

  /// Puts the model's own questions to the user. One answer per question, null
  /// where they answered nothing.
  final Future<List<String?>> Function(AskRequest request) answer;

  /// What the model may call. `bash` is dropped where nothing can run it —
  /// offering a tool we could only ever answer with a failure invites one.
  List<LlmTool> get _tools => [if (shell.canRunCommands) bashTool, askTool];

  bool _cancelled = false;
  ShellRun? _running;

  /// One step's scratch: what the model call produced, and whether a command
  /// ended the turn. Fields rather than out-parameters because an `async*`
  /// method has no return value of its own, and the turn is single-threaded.
  LlmCompletion? _completion;
  Object? _queryError;
  bool _submitted = false;

  /// Stop the turn. Kills whatever is running: an aborted turn that leaves a
  /// build going is not aborted.
  Future<void> cancel() async {
    _cancelled = true;
    await _running?.kill();
  }

  Stream<AgentEvent> run(
    String task, {
    List<LlmAttachment> attachments = const [],
    String? agentPrompt,
  }) async* {
    _openTurn(task, attachments, agentPrompt);

    var formatErrors = 0;
    for (var step = 0; step < options.stepLimit; step++) {
      if (_cancelled) break;

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

      if (completion.message.toolCalls.isEmpty) {
        // With no shell there is nothing to call, so a reply with no command
        // in it is the whole answer rather than a mistake.
        if (!shell.canRunCommands) break;
        formatErrors++;
        if (formatErrors >= options.maxConsecutiveFormatErrors) {
          yield ErrorEvent(
              "The model stopped calling the bash tool after $formatErrors tries.");
          break;
        }
        session.messages.add(LlmMessage(
          role: LlmRole.user,
          text: formatError(finishReason: completion.finishReason),
        ));
        continue;
      }
      formatErrors = 0;

      _submitted = false;
      yield* _executeAll(completion.message.toolCalls);
      if (_submitted || _cancelled) break;

      if (step == options.stepLimit - 1) {
        yield ErrorEvent("Stopped after ${options.stepLimit} steps without finishing. "
            "Ask again to carry on.");
      }
    }

    yield const DoneEvent();
  }

  /// The system prompt is rewritten every turn rather than once, so an
  /// `@agent` mention applies to the turn that used it whether or not the
  /// session is new.
  void _openTurn(String task, List<LlmAttachment> attachments, String? agentPrompt) {
    final system = LlmMessage(
      role: LlmRole.system,
      text: systemPrompt(
        workspace: workspace,
        projectWorkspace: projectWorkspace,
        platform: shell.platformDescription,
        agentPrompt: agentPrompt,
        canRunCommands: shell.canRunCommands,
      ),
    );
    final fresh = session.isFresh;
    if (session.messages.firstOrNull?.role == LlmRole.system) {
      session.messages[0] = system;
    } else {
      session.messages.insert(0, system);
    }
    session.messages.add(LlmMessage(
      role: LlmRole.user,
      // Only the first prompt is dressed as a task; the rest continue it.
      text: fresh ? firstTask(task) : task,
      attachments: attachments,
    ));
  }

  /// Every call the model made gets an answer, including the ones we never ran:
  /// a provider that sees a tool call with no result rejects the next turn.
  Stream<AgentEvent> _executeAll(List<LlmToolCall> calls) async* {
    for (final call in calls) {
      if (_submitted || _cancelled) {
        _answerRun(call, const ShellResult.failed("This command was not executed."));
        continue;
      }

      if (call.name == askToolName) {
        yield* _ask(call);
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

      final ShellResult result;
      if (requireApproval) {
        final approval = ToolApproval(
          id: call.id,
          toolName: "bash",
          argumentsJson: jsonEncode({"command": command}),
        );
        // Emitted before it is awaited: the banner is what the answer comes
        // from, so waiting first would wait forever.
        yield ApprovalRequestEvent(approval);
        result = await approve(approval) == ApprovalResponse.deny
            ? const ShellResult.failed("The user denied this command. Ask them what to do "
                "instead, or try something else.")
            : await _execute(command);
      } else {
        result = await _execute(command);
      }

      yield ToolResultEvent(ToolResult(
        callId: call.id,
        returnCode: result.returnCode,
        output: result.output,
        exceptionInfo: result.exceptionInfo,
      ));

      final submission = _submissionOf(result);
      if (submission != null) {
        _submitted = true;
        if (submission.isNotEmpty) yield TextDelta(submission);
      }

      _answerRun(call, result);
    }
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

  /// A call that could not be run at all: the UI still sees the pair, and the
  /// model still gets told why.
  Stream<AgentEvent> _reject(LlmToolCall call, String problem) async* {
    yield ToolCallEvent(
        ToolCall(id: call.id, name: call.name, argumentsJson: call.argumentsJson));
    yield ToolResultEvent(
        ToolResult(callId: call.id, returnCode: -1, output: "", exceptionInfo: problem));
    _answerRun(call, ShellResult.failed(problem));
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
  Stream<AgentEvent> _query() async* {
    for (var attempt = 1; attempt <= options.maxAttempts; attempt++) {
      var produced = false;
      DateTime? thinkingSince;

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

            case LlmTextChunk(:final text):
              produced = true;
              // Thinking ended when the reply started, not when the call did.
              if (thinkingSince != null) {
                yield ReasoningEnd(duration: DateTime.now().difference(thinkingSince));
                thinkingSince = null;
              }
              yield TextDelta(text);

            case LlmCompletion():
              if (thinkingSince != null) {
                yield ReasoningEnd(duration: DateTime.now().difference(thinkingSince));
              } else if (chunk.message.reasoning != null) {
                // A provider that reports thinking only once it is over still
                // fills the block.
                yield ReasoningEnd(text: chunk.message.reasoning);
              }
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
        if (!e.retryable || produced || attempt == options.maxAttempts) {
          _queryError = e;
          return;
        }
        yield RetryEvent(attempt: attempt, message: e.toString());
        await Future<void>.delayed(options.retryBackoff * (1 << (attempt - 1)));
      } catch (e) {
        _queryError = e;
        return;
      }
    }
  }

  /// The command asked to finish: upstream's contract is the marker alone on
  /// the first line of a command that succeeded, and whatever follows is the
  /// reply.
  String? _submissionOf(ShellResult result) {
    if (result.returnCode != 0) return null;
    final lines = const LineSplitter().convert(result.output.trimLeft());
    if (lines.isEmpty || lines.first.trim() != submitMarker) return null;
    return lines.skip(1).join("\n").trim();
  }

  String? _commandOf(LlmToolCall call) {
    try {
      final args = jsonDecode(call.argumentsJson.isEmpty ? "{}" : call.argumentsJson);
      if (args is! Map) return null;
      final command = args["command"];
      return command is String && command.isNotEmpty ? command : null;
    } catch (_) {
      return null;
    }
  }
}
