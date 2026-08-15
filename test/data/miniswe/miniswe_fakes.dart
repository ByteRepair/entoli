import "dart:async";
import "dart:convert";

import "package:agent_chat/data/miniswe/llm/llm_client.dart";
import "package:agent_chat/domain/shell.dart";

/// A model that says whatever the test scripted, one list of chunks per call.
class FakeLlmClient implements LlmClient {
  FakeLlmClient(this.turns);

  /// One entry per model call, in order. A turn that throws is how a failing
  /// request is scripted.
  final List<List<LlmChunk>> turns;

  /// What each call was sent, so a test can assert the observation the model
  /// was shown rather than only the event the UI saw.
  final List<List<LlmMessage>> sent = [];
  final List<({String model, double? temperature, String? reasoningEffort})> calls = [];

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
    calls.add((model: model, temperature: temperature, reasoningEffort: reasoningEffort));
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

/// A shell that answers from a table instead of running anything.
class FakeShell extends Shell {
  FakeShell(this.respond, {this.canRunCommands = true});

  final ShellResult Function(String command) respond;

  final List<String> ran = [];
  final List<String> killed = [];

  /// Commands that never finish on their own, so a test can drive an abort.
  final Set<String> hang = {};

  @override
  final bool canRunCommands;

  @override
  String get platformDescription => "TestOS 1.0 test";

  @override
  ShellRun start(String command, {required String cwd, required Duration timeout}) {
    ran.add(command);
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
  Future<void> kill() async {
    shell.killed.add(command);
    if (!_done.isCompleted) {
      _done.complete(const ShellResult.failed("The command was interrupted and killed."));
    }
  }
}

/// One assistant turn that calls `bash` with [command].
LlmCompletion bashCall(String command, {String id = "call-1", String text = ""}) =>
    LlmCompletion(
      message: LlmMessage(
        role: LlmRole.assistant,
        text: text,
        toolCalls: [
          LlmToolCall(id: id, name: "bash", argumentsJson: jsonEncode({"command": command})),
        ],
      ),
    );

/// One assistant turn that says something and calls nothing.
LlmCompletion saidOnly(String text, {String? finishReason}) => LlmCompletion(
      finishReason: finishReason,
      message: LlmMessage(role: LlmRole.assistant, text: text),
    );

ShellResult ok(String output) => ShellResult(returnCode: 0, output: output);
