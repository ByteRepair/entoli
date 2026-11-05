import "dart:async";
import "dart:convert";
import "dart:io";

import "package:collection/collection.dart";
import "package:path/path.dart" as p;

import "../../../../core/log.dart";
import "../../../../domain/llm_provider.dart";
import "../../../../domain/model_info.dart";
import "../../../../domain/tool_arg.dart";
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
/// all off; Entoli's are offered over a [ToolBridge], so a tool the model
/// calls runs in Entoli's loop, and the CLI waits on the held call until the
/// loop's next step brings the result.
class ClaudeCliProvider extends CliProvider {
  const ClaudeCliProvider([LlmProviderConfig config = preset])
    : this.over(config);

  /// With the process and the tool bridge given rather than real: what a
  /// test runs a session over.
  const ClaudeCliProvider.over(
    super.config, {
    this.launch = launchProcess,
    this.bindBridge = McpToolBridge.bind,
  });

  /// How a session starts `claude`.
  final LaunchCli launch;

  /// How a session offers Entoli's tools to it.
  final BindToolBridge bindBridge;

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

  @override
  String get about =>
      "Runs Claude CLI on this computer, signed in as it already is. "
      "Its own tools are off; it uses Entoli's.";

  @override
  String get account => "Uses your Claude account";

  @override
  String get workFolder => "claude-cli";

  @override
  String get bundler => "Claude Desktop";

  /// Claude Desktop's own `claude`, newest version first. It keeps each under
  /// `claude-code/<version>/<build>/`, replacing the directory on an update,
  /// so the path is found when asked rather than stored. Run outside a
  /// Desktop session, it signs in the way a `claude` installed on its own
  /// does. Only macOS's location is known.
  @override
  List<String> get bundledCopies {
    final home = Platform.environment["HOME"];
    if (!Platform.isMacOS || home == null) return const [];
    return desktopCopiesIn(
      p.join(home, "Library", "Application Support", "Claude", "claude-code"),
    );
  }

  /// The executables under [root], `<version>/<build>/claude.app/...`, by
  /// version, newest first.
  static List<String> desktopCopiesIn(String root) {
    final dir = Directory(root);
    if (!dir.existsSync()) return const [];
    List<int> version(String path) => [
      for (final part in p.basename(path).split(".")) int.tryParse(part) ?? -1,
    ];
    final versions = dir.listSync().whereType<Directory>().toList()
      ..sort((a, b) {
        final x = version(a.path), y = version(b.path);
        for (var i = 0; i < x.length && i < y.length; i++) {
          if (x[i] != y[i]) return y[i].compareTo(x[i]);
        }
        return y.length.compareTo(x.length);
      });
    return [
      for (final v in versions)
        for (final build in v.listSync().whereType<Directory>())
          p.join(build.path, "claude.app", "Contents", "MacOS", "claude"),
    ];
  }

  /// Everything a running Claude Code session gave this app, where it was
  /// started from inside one — a Claude Code terminal, a Claude Desktop
  /// session — and nothing of it otherwise. `CLAUDECODE` is how a session
  /// marks what it starts; under it, every `CLAUDE*`, `ANTHROPIC_*` and
  /// `MCP_*` variable is that session's — its id, its account and email, its
  /// proxy for the API — and handed on, they would make this `claude` a child
  /// of a session it has nothing to do with. A variable the user wants passed
  /// anyway goes in the provider's environment, which is laid over this.
  @override
  bool inherits(String name, Map<String, String> inherited) =>
      !inherited.containsKey("CLAUDECODE") ||
      !(name.startsWith("CLAUDE") ||
          name.startsWith("ANTHROPIC_") ||
          name.startsWith("MCP_"));

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

  final Directory _dir;
  CliProcess? _process;
  ToolBridge? _bridge;

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

  final _stderr = StderrTail();

  static final _prefix = "mcp__${McpToolRoutes.serverName}__";

  static Future<ClaudeCliSession> start(
    ClaudeCliProvider provider,
    CliSessionSpec spec,
  ) async {
    final executable = provider.executable();
    // The files it is handed go in a folder of the session's own, which
    // goes with it.
    final sessions = Directory(p.join(provider.workRoot.path, "sessions"));
    await sessions.create(recursive: true);
    final dir = await sessions.createTemp();
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
        : await provider.bindBridge(tools, _held);
    _bridge = bridge;
    final mcpConfig = File(p.join(_dir.path, "mcp.json"));
    await mcpConfig.writeAsString(
      jsonEncode({
        "mcpServers": {McpToolRoutes.serverName: ?bridge?.config},
      }),
    );
    final system = File(p.join(_dir.path, "system.md"));
    if (spec.system.isNotEmpty) await system.writeAsString(spec.system);
    final effort = effortOf(spec.reasoningEffort);
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
        "mcp__${McpToolRoutes.serverName}",
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
    final process = await provider.launch(
      executable,
      args,
      // No project's CLAUDE.md or settings are picked up from it, and its
      // cache's MCP logs and project entry are kept once.
      workingDirectory: await provider.workDirectory(),
      environment: {
        // A tool can wait on an approval for as long as the user takes.
        "MCP_TOOL_TIMEOUT": "${const Duration(days: 1).inMilliseconds}",
        ...env,
      },
    );
    _process = process;
    process.lines.listen(_line, onError: (Object e) => _fail("$e"));
    process.errors.listen(_stderr.add);
    unawaited(process.exitCode.then(_exited));
  }

  @override
  bool get alive => _alive;

  @override
  bool accepts(List<LlmMessage> rest) {
    if (!alive || _current != null || rest.isEmpty) return false;
    if (_fresh) return true;
    if (_uses.isNotEmpty) {
      return answersAll(rest, [for (final u in _uses) u.id]);
    }
    return rest.every(fromUser);
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
    final (:history, :tail) = splitTail(rest);
    return [
      if (history.isNotEmpty) {"type": "text", "text": transcriptOf(history)},
      for (final message in tail) ...AnthropicClient.userBlocks(message),
      if (tail.isEmpty) {"type": "text", "text": carryOn},
    ];
  }

  void _send(List<Map<String, dynamic>> content) {
    _process?.writeLine(
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
                (s) => s is Map && s["name"] == McpToolRoutes.serverName,
              )
            : null;
        if (_bridge != null && ours is Map && ours["status"] == "failed") {
          _fail("Claude CLI could not reach Entoli's tools");
        }
      case "result":
        if (_current == null) return;
        // A turn that ended with no reply streamed — an API error the CLI
        // reports in its own words, a limit it hit.
        final errors = event["errors"];
        final said =
            event["result"] as String? ??
            (errors is List ? errors.join("\n") : null) ??
            "${event["subtype"]}";
        if (event["is_error"] == true || event["subtype"] != "success") {
          _end(error: LlmException(said));
        } else {
          _end(
            last: LlmCompletion(
              message: LlmMessage(role: LlmRole.assistant, text: said),
              finishReason: "stop",
            ),
          );
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
      _end(error: e);
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
          _ToolUse(
            call.id,
            call.name,
            decodeArgs(call.argumentsJson) ?? const <String, dynamic>{},
          ),
        );
      }
      final orphans = [..._orphans];
      _orphans.clear();
      orphans.forEach(_held);
    }
    _end(
      last: LlmCompletion(
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
    );
  }

  /// A call from the CLI, paired with the reply's tool use it is for: by name
  /// and input where one matches, else the first of its name still unpaired.
  void _held(HeldToolCall call) {
    if (!alive) {
      call.fail(HeldToolCall.stopped);
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
    _alive = false;
    _end(error: LlmException(reason));
  }

  /// Ends the exchange in progress, if any, with [last] or [error]. It is
  /// detached first, so nothing that follows reaches it.
  void _end({LlmChunk? last, Object? error}) {
    final out = _current;
    _current = null;
    if (out == null) return;
    if (error != null) out.addError(error);
    if (last != null) out.add(last);
    unawaited(out.close());
  }

  void _exited(int code) {
    _alive = false;
    if (_closing) return;
    final said = _stderr.toString();
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
      use.call?.fail(HeldToolCall.stopped);
    }
    for (final call in _orphans) {
      call.fail(HeldToolCall.stopped);
    }
    _uses.clear();
    _orphans.clear();
    final process = _process;
    if (process != null) await stopProcess(process, "claude");
    try {
      await _dir.delete(recursive: true);
    } on FileSystemException catch (e) {
      logFailure("llm", "removing a Claude CLI session's files failed", e);
    }
    // Last, so a bridge that has closed is a session that is wholly gone.
    await _bridge?.close();
  }
}

class _ToolUse {
  _ToolUse(this.id, this.name, this.arguments);

  final String id;
  final String name;
  final Object? arguments;
  HeldToolCall? call;
  LlmMessage? result;
}
