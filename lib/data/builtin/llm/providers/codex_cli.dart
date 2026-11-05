import "dart:async";
import "dart:convert";
import "dart:io";

import "package:path/path.dart" as p;

import "../../../../core/log.dart";
import "../../../../domain/llm_provider.dart";
import "../../../../domain/model_info.dart";
import "../llm_client.dart";
import "../openai_client.dart" show inlineText;
import "cli.dart";

/// Codex CLI (`codex`) as a provider: the user's own ChatGPT sign-in
/// answering Entoli's turns.
///
/// A session is one `codex app-server`, Codex's JSON-RPC over stdio, holding
/// one ephemeral thread for a conversation: each step's new message starts a
/// turn on it, and its items stream back as notifications. Codex's own tools
/// are switched off; Entoli's are the thread's dynamic tools, which Codex
/// calls back over the same pipe and waits on until the loop's next step
/// brings the result.
class CodexCliProvider extends CliProvider {
  const CodexCliProvider([LlmProviderConfig config = preset])
    : this.over(config);

  /// With the process given rather than real: what a test runs a session
  /// over.
  const CodexCliProvider.over(super.config, {this.launch = launchProcess});

  /// How a session starts `codex`.
  final LaunchCli launch;

  static const preset = LlmProviderConfig(
    name: "Codex CLI",
    api: LlmApi.codexCli,
    baseUrl: "",
    defaultModelId: "gpt-6-luna",
    defaultLightModelId: "gpt-5.6-luna",
  );

  @override
  String get defaultCommand => "codex";

  @override
  String get about =>
      "Runs Codex CLI on this computer, signed in as it already is. "
      "Its own tools are off; it uses Entoli's.";

  @override
  String get account => "Uses your ChatGPT account";

  @override
  String get workFolder => "codex-cli";

  @override
  String get bundler => "the ChatGPT app";

  /// The ChatGPT app's own `codex`. Only macOS's location is known.
  @override
  List<String> get bundledCopies {
    if (!Platform.isMacOS) return const [];
    const inApp = "ChatGPT.app/Contents/Resources/codex-cli/bin/codex";
    final home = Platform.environment["HOME"];
    return [
      "/Applications/$inApp",
      if (home != null) p.join(home, "Applications", inApp),
    ];
  }

  /// The models a ChatGPT account is offered. Which it is offered depends on
  /// the plan; one missing here is added as the provider's own.
  @override
  List<ModelInfo> get knownModels => _known;

  static final _known = [
    for (final (id, name) in const [
      ("gpt-6-luna", "GPT-6-Luna"),
      ("gpt-5.6-terra", "GPT-5.6-Terra"),
      ("gpt-5.6-luna", "GPT-5.6-Luna"),
    ])
      ModelInfo(
        id: id,
        name: name,
        readsImages: true,
        reasoning: true,
        toolCall: true,
        context: 272000,
      ),
  ];

  /// Where Codex keeps its config: `CODEX_HOME`, or `~/.codex`.
  String? get codexHome {
    final env = environment;
    final home = env["HOME"] ?? env["USERPROFILE"];
    return env["CODEX_HOME"] ?? (home == null ? null : p.join(home, ".codex"));
  }

  /// The MCP servers the user's own Codex config declares, which a session
  /// switches off by name: an override cannot empty the table.
  List<String> userMcpServers() {
    final home = codexHome;
    if (home == null) return const [];
    final file = File(p.join(home, "config.toml"));
    try {
      return file.existsSync() ? mcpServersIn(file.readAsStringSync()) : [];
    } on FileSystemException catch (e) {
      logFailure("llm", "reading Codex's config failed", e);
      return const [];
    }
  }

  /// The names of the `[mcp_servers.<name>]` tables in [toml], each once.
  static List<String> mcpServersIn(String toml) => {
    for (final m in RegExp(
      r'^\s*\[\s*mcp_servers\.(?:"([^"]+)"|([A-Za-z0-9_-]+))',
      multiLine: true,
    ).allMatches(toml))
      (m[1] ?? m[2])!,
  }.toList();

  /// Codex's features that are tools of its own or reach past Entoli: each
  /// switched off. By config rather than `--disable`, which refuses a name
  /// a release no longer has where config only warns.
  static const _offFeatures = [
    "shell_tool",
    "unified_exec",
    "view_image",
    "image_generation",
    "goals",
    "apps",
    "plugins",
    "multi_agent",
    "tool_suggest",
    "skill_search",
    "computer_use",
    "browser_use",
    "in_app_browser",
    "hooks",
    "memories",
  ];

  /// `codex app-server`'s arguments, with the user's [mcpServers] off.
  static List<String> argumentsFor(List<String> mcpServers) => [
    "app-server",
    for (final feature in _offFeatures) ...["-c", "features.$feature=false"],
    for (final setting in [
      'web_search="disabled"',
      "tools.experimental_request_user_input={enabled=false}",
      "skills.bundled.enabled=false",
      "include_environment_context=false",
      "include_permissions_instructions=false",
      // The ChatGPT app sets a program of its own to run at every turn's end.
      "notify=[]",
      for (final name in mcpServers)
        "mcp_servers.${RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name) ? name : jsonEncode(name)}.enabled=false",
    ]) ...["-c", setting],
  ];

  @override
  Future<CliSession> start(CliSessionSpec spec) =>
      CodexCliSession.start(this, spec);
}

/// One `codex app-server` and the one thread it holds.
///
/// A reply ends where Codex calls Entoli's tools: the calls are the reply's,
/// Codex waits on each request, and the next step's results answer them. A
/// model whose tools are called from a script it runs (Codex's code mode)
/// calls them the same way. Calls that arrive together are one reply; one
/// that arrives after its reply was handed on goes out with the next.
class CodexCliSession extends CliSession {
  CodexCliSession._(super.spec, this._process);

  final CliProcess _process;
  late final String _thread;

  var _alive = true;
  var _closing = false;
  var _fresh = true;

  /// Whether a Codex turn is open: from `turn/start` to `turn/completed`.
  var _turnOpen = false;

  /// The exchange in progress, null between them.
  StreamController<LlmChunk>? _current;

  /// What the exchange in progress has said so far.
  final _text = StringBuffer();
  final _reasoning = StringBuffer();
  LlmUsage? _usage;

  /// Calls Codex made that no reply has carried yet.
  final _queued = <_Call>[];
  var _handing = false;

  /// Calls handed to the loop, by call id, waiting on its results.
  final _reported = <String, _Call>{};

  var _nextId = 0;
  final _waiting = <int, Completer<Object?>>{};
  final _stderr = StderrTail();

  static Future<CodexCliSession> start(
    CodexCliProvider provider,
    CliSessionSpec spec,
  ) async {
    final executable = provider.executable();
    final CliProcess process;
    try {
      process = await provider.launch(
        executable,
        CodexCliProvider.argumentsFor(provider.userMcpServers()),
        workingDirectory: await provider.workDirectory(),
        environment: provider.environment,
      );
    } catch (e) {
      throw LlmException("Could not start ${provider.command}: $e");
    }
    final session = CodexCliSession._(spec, process);
    try {
      await session._open(await provider.workDirectory());
    } catch (e) {
      await session.close();
      if (e is LlmException) rethrow;
      throw LlmException("Could not start ${provider.command}: $e");
    }
    return session;
  }

  Future<void> _open(String cwd) async {
    _process.lines.listen(_line, onError: (Object e) => _fail("$e"));
    _process.errors.listen(_stderr.add);
    unawaited(_process.exitCode.then(_exited));
    await _request("initialize", {
      "clientInfo": {"name": "entoli", "title": "Entoli", "version": "1"},
      // Dynamic tools are an experimental field.
      "capabilities": {"experimentalApi": true},
    });
    _write({"method": "initialized"});
    final started = await _request("thread/start", {
      "model": spec.model,
      "cwd": cwd,
      "ephemeral": true,
      // No machine to run on: Entoli's tools are the only way out.
      "environments": const <Object>[],
      "sandbox": "read-only",
      "approvalPolicy": "never",
      if (spec.system.isNotEmpty) "baseInstructions": spec.system,
      "dynamicTools": [
        for (final tool in spec.tools)
          {
            "type": "function",
            "name": tool.name,
            "description": tool.description,
            "inputSchema": tool.schema,
          },
      ],
    });
    _thread = ((started as Map)["thread"] as Map)["id"] as String;
  }

  @override
  bool get alive => _alive;

  @override
  bool accepts(List<LlmMessage> rest) {
    if (!alive || _current != null || rest.isEmpty) return false;
    if (_fresh) return true;
    if (_reported.isNotEmpty) return answersAll(rest, [..._reported.keys]);
    return !_turnOpen && rest.every(fromUser);
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
    _fresh = false;
    if (_reported.isNotEmpty) {
      // The results Codex's held calls are waiting on. Answering them is
      // what lets it carry on to its next reply.
      for (final result in rest) {
        final call = _reported.remove(result.toolCallId)!;
        _respond(call.request, _resultOf(result));
      }
      _handOutSoon();
    } else {
      _turnOpen = true;
      _request("turn/start", {
        "threadId": _thread,
        "input": _input(rest),
        "effort": ?effortOf(spec.reasoningEffort),
        "summary": "auto",
      }).catchError((Object e) {
        _turnOpen = false;
        _end(error: e);
        return null;
      });
    }
    return out.stream;
  }

  /// [rest] as a turn's input. A fresh session handed a history is told it
  /// as a transcript, with the trailing user turns as themselves.
  static List<Map<String, dynamic>> _input(List<LlmMessage> rest) {
    final (:history, :tail) = splitTail(rest);
    Map<String, dynamic> text(String text) => {"type": "text", "text": text};
    return [
      if (history.isNotEmpty) text(transcriptOf(history)),
      for (final message in tail) ...[
        text(inlineText(message)),
        for (final file in message.attachments)
          if (file.isImage)
            {"type": "image", "url": _dataUrl(file)}
          else if (file.isBlock)
            text("(attached: ${file.filename}, ${file.mimeType})"),
      ],
      if (tail.isEmpty) text(carryOn),
    ];
  }

  /// A tool result as Codex takes one back.
  static Map<String, dynamic> _resultOf(LlmMessage result) => {
    "contentItems": [
      {"type": "inputText", "text": inlineText(result)},
      for (final file in result.attachments)
        if (file.isImage) {"type": "inputImage", "imageUrl": _dataUrl(file)},
    ],
    "success": true,
  };

  static String _dataUrl(LlmAttachment file) =>
      "data:${file.mimeType};base64,${file.base64}";

  void _line(String line) {
    if (line.trim().isEmpty) return;
    final Map<String, dynamic> message;
    try {
      message = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final method = message["method"] as String?;
    final id = message["id"];
    final params = message["params"];
    if (method == null) {
      _answered(id, message);
    } else if (id != null) {
      _asked(id, method, params is Map<String, dynamic> ? params : const {});
    } else if (params is Map<String, dynamic>) {
      _notified(method, params);
    }
  }

  /// A response to one of this session's requests.
  void _answered(Object? id, Map<String, dynamic> message) {
    final waiting = _waiting.remove(id);
    if (waiting == null) return;
    final error = message["error"];
    if (error != null) {
      waiting.completeError(
        LlmException(error is Map ? "${error["message"]}" : "$error"),
      );
    } else {
      waiting.complete(message["result"]);
    }
  }

  /// A request from Codex. Only a tool call is Entoli's to answer; anything
  /// else — an approval, a question — is refused, there being nobody to ask.
  void _asked(Object id, String method, Map<String, dynamic> params) {
    if (method != "item/tool/call") {
      _write({
        "id": id,
        "error": {"code": -32601, "message": "Entoli does not answer $method"},
      });
      return;
    }
    final call = _Call(
      id,
      params["callId"] as String,
      params["tool"] as String,
      params["arguments"],
    );
    if (!alive) {
      _respond(id, _failed);
      return;
    }
    _queued.add(call);
    _handOutSoon();
  }

  void _notified(String method, Map<String, dynamic> params) {
    switch (method) {
      case "item/agentMessage/delta":
        _say(_text, "${params["delta"]}", LlmTextChunk.new);
      case "item/reasoning/summaryTextDelta" || "item/reasoning/textDelta":
        _say(_reasoning, "${params["delta"]}", LlmReasoningChunk.new);
      case "item/started":
        // A second message in one reply, after a tool Codex ran itself.
        final item = params["item"];
        if (item is Map && item["type"] == "agentMessage" && _text.isNotEmpty) {
          _say(_text, "\n\n", LlmTextChunk.new);
        }
      case "thread/tokenUsage/updated":
        final last = (params["tokenUsage"] as Map?)?["last"];
        if (last is Map) {
          final cached = (last["cachedInputTokens"] as num?)?.toInt() ?? 0;
          _usage = LlmUsage(
            inputTokens: ((last["inputTokens"] as num?)?.toInt() ?? 0) - cached,
            outputTokens: (last["outputTokens"] as num?)?.toInt() ?? 0,
            cacheReadTokens: cached,
          );
        }
      case "turn/completed":
        _turnCompleted(params["turn"] as Map? ?? const {});
    }
  }

  /// Adds [delta] to [said] and streams it, where an exchange is open. One
  /// that is not is Codex going on without Entoli's loop, and what it holds
  /// is no longer the conversation the loop has.
  void _say(StringBuffer said, String delta, LlmChunk Function(String) chunk) {
    final out = _current;
    if (out == null) {
      _alive = false;
      return;
    }
    said.write(delta);
    out.add(chunk(delta));
  }

  void _turnCompleted(Map<dynamic, dynamic> turn) {
    _turnOpen = false;
    // A turn that ended leaves nothing waiting on its calls.
    for (final call in [..._queued, ..._reported.values]) {
      _respond(call.request, _failed);
    }
    _queued.clear();
    _reported.clear();
    final status = turn["status"];
    if (status == "completed") {
      _end(
        last: LlmCompletion(
          finishReason: "stop",
          usage: _usage,
          message: _reply(const []),
        ),
      );
      return;
    }
    final error = turn["error"];
    final unauthorized =
        error is Map &&
        jsonEncode(error["codexErrorInfo"]).contains('"httpStatusCode":401');
    _end(
      error: LlmException(
        unauthorized
            ? "Codex CLI is not signed in. Run `codex login`, or sign in in "
                  "the ChatGPT app."
            : error is Map
            ? "${error["message"]}"
            : "Codex's turn ended $status",
      ),
    );
  }

  /// Hands out the calls that have arrived, once whatever else arrived with
  /// them has been read: calls made together are one reply.
  void _handOutSoon() {
    if (_handing || _current == null) return;
    _handing = true;
    Timer.run(() {
      _handing = false;
      if (_current == null || _queued.isEmpty) return;
      final calls = [..._queued];
      _queued.clear();
      for (final call in calls) {
        _reported[call.id] = call;
      }
      _end(
        last: LlmCompletion(
          finishReason: "tool_use",
          usage: _usage,
          message: _reply([
            for (final call in calls)
              LlmToolCall(
                id: call.id,
                name: call.name,
                argumentsJson: jsonEncode(call.arguments ?? const {}),
              ),
          ]),
        ),
      );
    });
  }

  LlmMessage _reply(List<LlmToolCall> calls) => LlmMessage(
    role: LlmRole.assistant,
    text: _text.toString(),
    reasoning: _reasoning.isEmpty ? null : _reasoning.toString(),
    toolCalls: calls,
  );

  static const _failed = {
    "contentItems": [
      {"type": "inputText", "text": "Entoli stopped this turn"},
    ],
    "success": false,
  };

  Future<Object?> _request(String method, Map<String, dynamic> params) {
    if (!_alive) return Future.error(const LlmException("Codex CLI is gone"));
    final id = ++_nextId;
    final done = Completer<Object?>();
    _waiting[id] = done;
    _write({"id": id, "method": method, "params": params});
    return done.future;
  }

  void _respond(Object id, Map<String, dynamic> result) =>
      _write({"id": id, "result": result});

  void _write(Map<String, dynamic> message) {
    if (_closing) return;
    _process.writeLine(jsonEncode(message));
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
    _text.clear();
    _reasoning.clear();
    _usage = null;
    if (out == null) return;
    if (error != null) out.addError(error);
    if (last != null) out.add(last);
    unawaited(out.close());
  }

  void _exited(int code) {
    _alive = false;
    final said = _stderr.toString();
    final reason = said.isEmpty
        ? "Codex CLI exited ($code)"
        : "Codex CLI exited ($code): $said";
    for (final waiting in _waiting.values) {
      waiting.completeError(LlmException(reason));
    }
    _waiting.clear();
    if (_closing) return;
    logFailure("llm", "codex exited with $code");
    _fail(reason);
  }

  @override
  Future<void> close() async {
    if (_closing) return;
    _alive = false;
    final out = _current;
    _current = null;
    await out?.close();
    // Ephemeral: the thread goes with the process, and nothing else is kept.
    _closing = true;
    await stopProcess(_process, "codex");
  }
}

/// A call Codex made and holds open: the request to answer, and what it is.
class _Call {
  _Call(this.request, this.id, this.name, this.arguments);

  final Object request;
  final String id;
  final String name;
  final Object? arguments;
}
