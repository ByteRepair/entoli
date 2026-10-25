import "dart:async";
import "dart:convert";

import "package:agent_chat/data/builtin/llm/llm_client.dart";
import "package:agent_chat/domain/artifact.dart";
import "package:agent_chat/domain/ask.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/shell.dart";
import "package:agent_chat/domain/web_search.dart";
import "package:flutter/foundation.dart"
    show ValueListenable;

/// A model that says whatever the test scripted, one list of chunks per call.
class FakeLlmClient implements LlmClient {
  FakeLlmClient(this.turns);

  /// One entry per model call, in order. A turn that throws is how a failing
  /// request is scripted.
  final List<List<LlmChunk>> turns;

  /// What each call was sent, so a test can assert the observation the model
  /// was shown rather than only the event the UI saw.
  final List<List<LlmMessage>> sent = [];
  final List<
      ({
        String model,
        List<LlmTool> tools,
        double? temperature,
        String? reasoningEffort
      })> calls = [];

  int _at = 0;
  bool closed = false;

  /// Thrown instead of streaming, for whichever calls name themselves here.
  final Map<int, Object> failures = {};

  @override
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) async* {
    final at = _at++;
    sent.add(List.of(messages));
    calls.add((
      model: model,
      tools: tools,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
    ));
    final failure = failures[at];
    if (failure != null) throw failure;
    if (at >= turns.length) throw StateError("no scripted turn $at");
    yield* Stream.fromIterable(turns[at]);
  }

  @override
  Future<List<String>> listModels() async => const ["fake-model"];

  @override
  void close() => closed = true;
}

/// Wraps a [FakeLlmClient] to track how many [stream] calls were in flight at
/// once, for asserting the [RateLimitGate]'s concurrency cap. Each call
/// increments a counter on entry and decrements it on stream close (normal,
/// thrown, or cancelled), recording the high-water mark in [maxConcurrent].
class ConcurrentFakeLlmClient implements LlmClient {
  ConcurrentFakeLlmClient(this.inner);

  final FakeLlmClient inner;

  int _inFlight = 0;
  int maxConcurrent = 0;

  @override
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) async* {
    _inFlight++;
    if (_inFlight > maxConcurrent) maxConcurrent = _inFlight;
    try {
      yield* inner.stream(
        messages,
        model: model,
        tools: tools,
        temperature: temperature,
        reasoningEffort: reasoningEffort,
      );
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<List<String>> listModels() => inner.listModels();

  @override
  void close() => inner.close();
}

/// A shell that answers from a table instead of running anything.
class FakeShell extends Shell {
  FakeShell(this.respond, {this.canRunCommands = true, this.home});

  final ShellResult Function(String command) respond;

  /// The machine user's home, where a test needs a `~` to land somewhere.
  final String? home;

  @override
  String? get machineHome => home;

  final List<String> ran = [];

  /// Where each of [ran] was started, in step with it.
  final List<String> cwds = [];

  /// The `HOME` each of [ran] was given, in step with it.
  final List<String> homes = [];

  /// The directories each command was told it must not write.
  final List<List<String>> readOnlys = [];

  /// The timeout each of [ran] was given, in step with it.
  final List<Duration> timeouts = [];

  /// The project environment each of [ran] was handed, in step with it.
  final List<Map<String, String>?> environments = [];

  /// Whether each of [ran] was a one-shot, in step with it.
  final List<bool> oneShots = [];

  /// Whether each of [ran] asked for a restart, in step with it.
  final List<bool> restarts = [];

  /// The sandbox each of [ran] was handed, in step with it.
  final List<CommandSandbox?> sandboxes = [];

  final List<String> killed = [];

  /// The sessions [closeSession] ended, in the order they ended.
  final List<String> closedSessions = [];

  /// Commands that never finish on their own, so a test can drive an abort.
  final Set<String> hang = {};

  /// What a hung command had printed by the time it was killed.
  String killedOutput = "";

  @override
  void closeSession(String cwd) => closedSessions.add(cwd);

  @override
  final bool canRunCommands;

  @override
  String get platformDescription => "TestOS 1.0 test";

  @override
  ShellRun start(String command,
      {required String cwd,
      required String home,
      required Duration timeout,
      Map<String, String>? environment,
      bool oneShot = false,
      bool restart = false,
      String? project,
      CommandSandbox? sandbox,
      List<String> readOnly = const []}) {
    ran.add(command);
    readOnlys.add(readOnly);
    cwds.add(cwd);
    homes.add(home);
    timeouts.add(timeout);
    environments.add(environment);
    oneShots.add(oneShot);
    restarts.add(restart);
    sandboxes.add(sandbox);
    return _FakeRun(this, command);
  }
}

class _FakeRun implements ShellRun {
  _FakeRun(this.shell, this.command) {
    if (!shell.hang.contains(command)) _done.complete(shell.respond(command));
  }

  final FakeShell shell;
  final String command;
  final Completer<ShellResult> _done = Completer();

  @override
  Future<ShellResult> get result => _done.future;

  @override
  ValueListenable<String?>? get output => null;

  @override
  Future<void> kill() async {
    shell.killed.add(command);
    if (!_done.isCompleted) {
      _done.complete(ShellResult.failed("The command was interrupted and killed.",
          output: shell.killedOutput));
    }
  }
}

/// One assistant turn that calls `bash` with [command].
LlmCompletion bashCall(
  String command, {
  String id = "call-1",
  String text = "",
  Map<String, Object?> extra = const {},
}) =>
    LlmCompletion(
      message: LlmMessage(
        role: LlmRole.assistant,
        text: text,
        toolCalls: [
          LlmToolCall(
              id: id, name: "bash", argumentsJson: jsonEncode({"command": command, ...extra})),
        ],
      ),
    );

/// One assistant turn that calls a tool by name with a map of arguments —
/// the shape any structured tool call takes in a test. Named for the file
/// tools because that is what most tests call, but not limited to them.
LlmCompletion fileCall(String tool, Map<String, Object?> arguments,
        {String id = "file-1"}) =>
    LlmCompletion(
      message: LlmMessage(
        role: LlmRole.assistant,
        toolCalls: [
          LlmToolCall(id: id, name: tool, argumentsJson: jsonEncode(arguments)),
        ],
      ),
    );

/// One assistant turn that asks the user something. [arguments] is passed as
/// the model wrote it, so a test can hand over a shape nobody designed for.
LlmCompletion askCall(Object arguments, {String id = "ask-1"}) => LlmCompletion(
      message: LlmMessage(
        role: LlmRole.assistant,
        toolCalls: [
          LlmToolCall(
            id: id,
            name: askToolName,
            argumentsJson: arguments is String ? arguments : jsonEncode(arguments),
          ),
        ],
      ),
    );

/// One assistant turn that says something and calls nothing.
LlmCompletion saidOnly(String text, {String? finishReason}) => LlmCompletion(
      finishReason: finishReason,
      message: LlmMessage(role: LlmRole.assistant, text: text),
    );

/// One assistant turn that spawns several sub-agents at once, the fan-out a
/// `task` batch is for. [tasks] is agent-name to prompt, and the call ids are
/// `t1`, `t2`, ... in the order given — which is the order the model made them.
LlmCompletion taskCalls(List<(String, String)> tasks) => LlmCompletion(
      message: LlmMessage(
        role: LlmRole.assistant,
        toolCalls: [
          for (final (i, (agent, prompt)) in tasks.indexed)
            LlmToolCall(
              id: "t${i + 1}",
              name: "task",
              argumentsJson: jsonEncode({"agent": agent, "prompt": prompt}),
            ),
        ],
      ),
    );

/// One assistant turn that spawns a sub-agent via the `task` tool.
LlmCompletion taskCall(String agent, String prompt, {String id = "task-1", String text = ""}) =>
    LlmCompletion(
      message: LlmMessage(
        role: LlmRole.assistant,
        text: text,
        toolCalls: [
          LlmToolCall(
            id: id,
            name: "task",
            argumentsJson: jsonEncode({"agent": agent, "prompt": prompt}),
          ),
        ],
      ),
    );

/// One assistant turn that calls `webfetch`.
LlmCompletion fetchCall(String url, {String id = "fetch-1", String text = ""}) =>
    LlmCompletion(
      message: LlmMessage(
        role: LlmRole.assistant,
        text: text,
        toolCalls: [
          LlmToolCall(
            id: id,
            name: "webfetch",
            argumentsJson: jsonEncode({"url": url}),
          ),
        ],
      ),
    );

/// One assistant turn that calls `artifact`.
LlmCompletion artifactCall(String path, {String? title, String? artifactId, String id = "art-1", String text = ""}) =>
    LlmCompletion(
      message: LlmMessage(
        role: LlmRole.assistant,
        text: text,
        toolCalls: [
          LlmToolCall(
            id: id,
            name: artifactToolName,
            argumentsJson: jsonEncode({
              "path": path,
              "title": ?title,
              "artifact_id": ?artifactId,
            }),
          ),
        ],
      ),
    );

/// One assistant turn that calls `read`.
LlmCompletion readCall(String path, {int? offset, int? limit, String id = "read-1", String text = ""}) =>
    LlmCompletion(
      message: LlmMessage(
        role: LlmRole.assistant,
        text: text,
        toolCalls: [
          LlmToolCall(
            id: id,
            name: "read",
            argumentsJson: jsonEncode({
              "path": path,
              "offset": ?offset,
              "limit": ?limit,
            }),
          ),
        ],
      ),
    );

/// One assistant turn that calls `write`.
LlmCompletion writeCall(String path, String content, {String id = "write-1", String text = ""}) =>
    LlmCompletion(
      message: LlmMessage(
        role: LlmRole.assistant,
        text: text,
        toolCalls: [
          LlmToolCall(
            id: id,
            name: "write",
            argumentsJson: jsonEncode({"path": path, "content": content}),
          ),
        ],
      ),
    );

/// One assistant turn that calls `edit`.
LlmCompletion editCall(
  String path,
  String oldString,
  String newString, {
  bool replaceAll = false,
  String id = "edit-1",
  String text = "",
}) =>
    LlmCompletion(
      message: LlmMessage(
        role: LlmRole.assistant,
        text: text,
        toolCalls: [
          LlmToolCall(
            id: id,
            name: "edit",
            argumentsJson: jsonEncode({
              "path": path,
              "old_string": oldString,
              "new_string": newString,
              if (replaceAll) "replace_all": true,
            }),
          ),
        ],
      ),
    );

/// A web search that answers from a table instead of reaching the network.
class FakeWebSearch extends WebSearch {
  FakeWebSearch({
    this.searchResult,
    this.fetchResult,
    this.available = true,
  });

  /// What `search` returns. Defaults to a generic success.
  ShellResult Function(String query)? searchResult;

  /// What `fetch` returns. Defaults to a generic success.
  ShellResult Function(String url)? fetchResult;

  @override
  final bool available;

  final List<String> searched = [];
  final List<String> fetched = [];

  @override
  Future<ShellResult> search(String query) async {
    searched.add(query);
    return searchResult?.call(query) ??
        const ShellResult(returnCode: 0, output: "No results.");
  }

  @override
  Future<ShellResult> fetch(String url) async {
    fetched.add(url);
    return fetchResult?.call(url) ??
        const ShellResult(returnCode: 0, output: "Page content.");
  }
}

ShellResult ok(String output, {String? cwd}) =>
    ShellResult(returnCode: 0, output: output, cwd: cwd);

/// A classifier that answers from a table instead of reaching a model.
class FakeClassifier implements PermissionClassifier {
  FakeClassifier({this.decision = PermissionDecision.allow});

  /// What every call returns. Tests that need per-command decisions swap this
  /// out between turns.
  PermissionDecision Function(String toolName, String arguments)? decide;

  /// The default decision when [decide] is not set.
  PermissionDecision decision;

  final List<({String tool, String args})> classified = [];

  /// The writable set each call was told, beside the workspace.
  final List<List<String>> alsoWritable = [];

  @override
  Future<PermissionDecision> classify(
    String toolName,
    String argumentsJson, {
    required String workspace,
    List<String> alsoWritable = const [],
  }) async {
    classified.add((tool: toolName, args: argumentsJson));
    this.alsoWritable.add(alsoWritable);
    return decide?.call(toolName, argumentsJson) ?? decision;
  }
}
