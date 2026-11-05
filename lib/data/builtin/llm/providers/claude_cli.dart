import "dart:async";
import "dart:convert";
import "dart:io";

import "package:collection/collection.dart";
import "package:path/path.dart" as p;

import "../../../../core/log.dart";
import "../../../../domain/llm_provider.dart";
import "../../../../domain/model_info.dart";
import "../anthropic_client.dart";
import "../llm_client.dart";
import "../mcp_tool_bridge.dart";
import "cli.dart";

/// Claude CLI (`claude`, Claude Code) as a provider: the user's own sign-in,
/// whatever plan it is on, answering Entoli's turns.
///
/// A session is one `claude -p` in stream-json mode on both sides, kept
/// running for a conversation: each step's new message goes in on stdin and
/// its raw Anthropic stream events come out on stdout. Claude's own tools are
/// all off; Entoli's are offered over an [McpToolBridge], so a tool the model
/// calls runs in Entoli's loop, and the CLI waits on the held call until the
/// loop's next step brings the result.
class ClaudeCliProvider extends CliProvider {
  const ClaudeCliProvider([super.config = preset]);

  static const preset = LlmProviderConfig(
    name: "Claude CLI",
    api: LlmApi.claudeCli,
    baseUrl: "",
    defaultModelId: "sonnet",
    defaultLightModelId: "haiku",
  );

  @override
  String get defaultCommand => "claude";

  @override
  bool get takesPdfs => true;

  /// The CLI's aliases, each the newest of its family.
  @override
  List<ModelInfo> get knownModels => _known;

  static final _known = [
    for (final (id, name) in const [
      ("opus", "Claude Opus (latest)"),
      ("sonnet", "Claude Sonnet (latest)"),
      ("haiku", "Claude Haiku (latest)"),
      ("fable", "Claude Fable (latest)"),
    ])
      ModelInfo(
        id: id,
        name: name,
        readsImages: true,
        readsPdfs: true,
        reasoning: true,
        toolCall: true,
        context: 200000,
      ),
  ];

  @override
  Future<CliSession> start(CliSessionSpec spec) =>
      ClaudeCliSession.start(this, spec);
}

/// One `claude -p --input-format stream-json --output-format stream-json`.
class ClaudeCliSession extends CliSession {
  ClaudeCliSession._(super.spec, this._dir);

  /// How long a closing session is given to go on its own, once stdin is
  /// closed, and then again after a SIGTERM.
  static const _grace = Duration(seconds: 3);

  final Directory _dir;
  Process? _process;
  McpToolBridge? _bridge;

  var _alive = true;
  var _closing = false;
  var _fresh = true;

  /// The exchange in progress, null between them.
  StreamController<LlmChunk>? _current;

  /// The API message being read, from its `message_start`.
  AnthropicEventReader? _reader;

  /// The tool calls of the last reply, waiting to be paired with the bridge
  /// call the CLI makes for each and with the result the loop brings back.
  final _uses = <_ToolUse>[];

  /// Bridge calls that came in before the reply that made them was read.
  final _orphans = <HeldToolCall>[];

  /// The last of what the CLI said on stderr, for an exit to explain itself.
  final _stderr = StringBuffer();

  static final _prefix = "mcp__${McpToolBridge.serverName}__";

  static Future<ClaudeCliSession> start(
    ClaudeCliProvider provider,
    CliSessionSpec spec,
  ) async {
    final executable = provider.executable();
    // Its working directory too: an empty one, so no project's CLAUDE.md or
    // settings are picked up from wherever the app was launched.
    final dir = await Directory.systemTemp.createTemp("entoli-claude-");
    final session = ClaudeCliSession._(spec, dir);
    try {
      await session._launch(provider, executable);
    } catch (e) {
      await session.close();
      if (e is LlmException) rethrow;
      throw LlmException("Could not start ${provider.command}: $e");
    }
    return session;
  }

  Future<void> _launch(ClaudeCliProvider provider, String executable) async {
    final tools = spec.tools;
    final bridge = tools.isEmpty
        ? null
        : await McpToolBridge.bind(tools, _held);
    _bridge = bridge;
    final mcpConfig = File(p.join(_dir.path, "mcp.json"));
    await mcpConfig.writeAsString(
      jsonEncode({
        "mcpServers": {McpToolBridge.serverName: ?bridge?.config},
      }),
    );
    final system = File(p.join(_dir.path, "system.md"));
    if (spec.system.isNotEmpty) await system.writeAsString(spec.system);
    final effort = _effortOf(spec.reasoningEffort);
    final args = [
      "-p",
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--verbose",
      "--include-partial-messages",
      "--model",
      spec.model,
      // Claude's own tools are off: what it can do is Entoli's to decide.
      "--tools",
      "",
      "--strict-mcp-config",
      "--mcp-config",
      mcpConfig.path,
      if (bridge != null) ...[
        "--allowedTools",
        "mcp__${McpToolBridge.serverName}",
      ],
      // Anything not allowed above is refused rather than asked about: a
      // built-in `--tools ""` leaves behind (EndConversation, while MCP tools
      // are present) cannot run, and there is nobody to ask anyway.
      "--permission-mode",
      "dontAsk",
      "--no-session-persistence",
      "--disable-slash-commands",
      if (spec.system.isNotEmpty) ...["--system-prompt-file", system.path],
      if (effort != null) ...["--effort", effort],
    ];
    final env = provider.environment;
    final process = await Process.start(
      executable,
      args,
      workingDirectory: _dir.path,
      environment: {
        // A tool can wait on an approval for as long as the user takes.
        "MCP_TOOL_TIMEOUT": "${const Duration(days: 1).inMilliseconds}",
        ...env,
      },
      includeParentEnvironment: false,
      // npm installs a `.cmd` shim on Windows, which only a shell runs.
      runInShell:
          Platform.isWindows &&
          const [
            ".cmd",
            ".bat",
          ].contains(p.extension(executable).toLowerCase()),
    );
    _process = process;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_line, onError: (Object e) => _fail("$e"));
    process.stderr.transform(utf8.decoder).listen((text) {
      _stderr.write(text);
      final over = _stderr.length - 4000;
      if (over > 0) {
        final kept = _stderr.toString().substring(over);
        _stderr
          ..clear()
          ..write(kept);
      }
    });
    unawaited(process.exitCode.then(_exited));
  }

  /// The loop's effort word as one the CLI takes.
  static String? _effortOf(String? effort) => switch (effort) {
    null => null,
    "minimal" => "low",
    "low" || "medium" || "high" || "xhigh" || "max" => effort,
    _ => null,
  };

  @override
  bool get alive => _alive && !_closing;

  @override
  bool accepts(List<LlmMessage> rest) {
    if (!alive || _current != null || rest.isEmpty) return false;
    if (_fresh) return true;
    if (_uses.isNotEmpty) {
      return rest.length == _uses.length &&
          rest.every((m) => m.role == LlmRole.tool) &&
          const SetEquality<String?>().equals(
            {for (final m in rest) m.toolCallId},
            {for (final u in _uses) u.id},
          );
    }
    return rest.every(
      (m) => m.role == LlmRole.user || m.role == LlmRole.system,
    );
  }

  @override
  Stream<LlmChunk> exchange(List<LlmMessage> rest) {
    final out = StreamController<LlmChunk>();
    if (!accepts(rest)) {
      out
        ..addError(const LlmException("The CLI session cannot take this"))
        ..close();
      return out.stream;
    }
    _current = out;
    if (_uses.isNotEmpty) {
      // The results the CLI's held calls are waiting on. Answering them is
      // what lets it carry on to its next reply.
      for (final result in rest) {
        _uses.firstWhere((u) => u.id == result.toolCallId).result = result;
      }
      _pair();
    } else {
      _send(_firstContent(rest));
    }
    _fresh = false;
    return out.stream;
  }

  /// [rest] as one user message's content. A fresh session handed a history
  /// is told it as a transcript, with the trailing user turns as themselves.
  List<Map<String, dynamic>> _firstContent(List<LlmMessage> rest) {
    final tail = rest.reversed
        .takeWhile((m) => m.role == LlmRole.user || m.role == LlmRole.system)
        .toList()
        .reversed
        .toList();
    final history = rest.sublist(0, rest.length - tail.length);
    return [
      if (history.isNotEmpty) {"type": "text", "text": transcriptOf(history)},
      for (final message in tail) ...AnthropicClient.userBlocks(message),
      if (tail.isEmpty)
        {
          "type": "text",
          "text": "Carry on from where the conversation leaves off.",
        },
    ];
  }

  void _send(List<Map<String, dynamic>> content) {
    _process?.stdin.writeln(
      jsonEncode({
        "type": "user",
        "message": {"role": "user", "content": content},
        "parent_tool_use_id": null,
      }),
    );
  }

  void _line(String line) {
    if (line.trim().isEmpty) return;
    final Map<String, dynamic> event;
    try {
      event = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (event["type"]) {
      case "stream_event":
        if (event["parent_tool_use_id"] != null) return;
        final inner = event["event"];
        if (inner is Map<String, dynamic>) _streamEvent(inner);
      case "system" when event["subtype"] == "init":
        final servers = event["mcp_servers"];
        final ours = servers is List
            ? servers.firstWhereOrNull(
                (s) => s is Map && s["name"] == McpToolBridge.serverName,
              )
            : null;
        if (_bridge != null && ours is Map && ours["status"] == "failed") {
          _fail("Claude CLI could not reach Entoli's tools");
        }
      case "result":
        final out = _current;
        if (out == null) return;
        // A turn that ended with no reply streamed — an API error the CLI
        // reports in its own words, a limit it hit.
        final errors = event["errors"];
        final said =
            event["result"] as String? ??
            (errors is List ? errors.join("\n") : null) ??
            "${event["subtype"]}";
        if (event["is_error"] == true || event["subtype"] != "success") {
          _current = null;
          out
            ..addError(LlmException(said))
            ..close();
        } else {
          _current = null;
          out
            ..add(
              LlmCompletion(
                message: LlmMessage(role: LlmRole.assistant, text: said),
                finishReason: "stop",
              ),
            )
            ..close();
        }
    }
  }

  void _streamEvent(Map<String, dynamic> event) {
    final out = _current;
    if (event["type"] == "message_start") _reader = AnthropicEventReader();
    final reader = _reader;
    if (reader == null) return;
    if (out == null) {
      // A reply nobody asked for: the CLI went on without Entoli's loop,
      // and what it holds is no longer the conversation the loop has.
      _alive = false;
      return;
    }
    try {
      for (final chunk in reader.read(event)) {
        out.add(chunk);
      }
    } on LlmException catch (e) {
      _current = null;
      out
        ..addError(e)
        ..close();
      return;
    }
    if (event["type"] != "message_stop") return;
    _reader = null;
    final done = reader.completion();
    final calls = [
      for (final call in done.message.toolCalls)
        LlmToolCall(
          id: call.id,
          name: call.name.startsWith(_prefix)
              ? call.name.substring(_prefix.length)
              : call.name,
          argumentsJson: call.argumentsJson,
        ),
    ];
    if (done.finishReason == "tool_use") {
      for (final call in calls) {
        _uses.add(
          _ToolUse(call.id, call.name, decodedArguments(call.argumentsJson)),
        );
      }
      final orphans = [..._orphans];
      _orphans.clear();
      orphans.forEach(_held);
    }
    _current = null;
    out
      ..add(
        LlmCompletion(
          finishReason: done.finishReason,
          usage: done.usage,
          message: LlmMessage(
            role: LlmRole.assistant,
            text: done.message.text,
            reasoning: done.message.reasoning,
            reasoningSignature: done.message.reasoningSignature,
            toolCalls: calls,
          ),
        ),
      )
      ..close();
  }

  /// A call from the CLI, paired with the reply's tool use it is for: by name
  /// and input where one matches, else the first of its name still unpaired.
  void _held(HeldToolCall call) {
    if (!alive) {
      call.fail("Entoli stopped this turn");
      return;
    }
    final open = _uses.where((u) => u.call == null);
    final use =
        open.firstWhereOrNull(
          (u) =>
              u.name == call.name &&
              const DeepCollectionEquality().equals(
                u.arguments,
                call.arguments,
              ),
        ) ??
        open.firstWhereOrNull((u) => u.name == call.name);
    if (use == null) {
      _orphans.add(call);
      return;
    }
    use.call = call;
    _pair();
  }

  /// Answers every call whose result is in.
  void _pair() {
    for (final use in _uses.toList()) {
      final call = use.call;
      final result = use.result;
      if (call == null || result == null) continue;
      call.answer(result);
      _uses.remove(use);
    }
  }

  void _fail(String reason) {
    final out = _current;
    _current = null;
    _alive = false;
    out
      ?..addError(LlmException(reason))
      ..close();
  }

  void _exited(int code) {
    _alive = false;
    if (_closing) return;
    final said = _stderr.toString().trim();
    logFailure("llm", "claude exited with $code");
    _fail(
      said.isEmpty
          ? "Claude CLI exited ($code)"
          : "Claude CLI exited ($code): $said",
    );
  }

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _alive = false;
    final out = _current;
    _current = null;
    await out?.close();
    for (final use in _uses) {
      use.call?.fail("Entoli stopped this turn");
    }
    for (final call in _orphans) {
      call.fail("Entoli stopped this turn");
    }
    _uses.clear();
    _orphans.clear();
    final process = _process;
    if (process != null) {
      try {
        // Stdin closed is the end of its input, which it takes as the end of
        // the session; a signal is for one that does not.
        await process.stdin.close().timeout(_grace, onTimeout: () {});
      } on Object catch (e) {
        logFailure("llm", "closing claude's input failed", e);
      }
      var exited = await _waitExit(process);
      if (!exited) {
        process.kill();
        exited = await _waitExit(process);
      }
      if (!exited) process.kill(ProcessSignal.sigkill);
    }
    await _bridge?.close();
    try {
      await _dir.delete(recursive: true);
    } on FileSystemException catch (e) {
      logFailure("llm", "removing a Claude CLI session's files failed", e);
    }
  }

  static Future<bool> _waitExit(Process process) => process.exitCode
      .then((_) => true)
      .timeout(_grace, onTimeout: () => false);
}

class _ToolUse {
  _ToolUse(this.id, this.name, this.arguments);

  final String id;
  final String name;
  final Object? arguments;
  HeldToolCall? call;
  LlmMessage? result;
}
