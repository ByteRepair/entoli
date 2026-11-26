import "dart:async";
import "dart:convert";
import "dart:math";

import "package:entoli_core/model/log.dart";
import "package:entoli_core/agent/llm/llm_client.dart";
import "package:entoli_core/agent/llm/openai_client.dart" show inlineText;

import "../mcp_tool_bridge.dart";
import "cli.dart";

/// A program that speaks the Agent Client Protocol on its stdio: GitHub
/// Copilot CLI's and Antigravity CLI's way of being driven by an editor, and
/// so by Entoli. What every such program shares is here — the session, the
/// sign-in check, the sign-out — and a subclass says how it is started and
/// what it keeps where.
///
/// Its own tools are refused by the subclass's flags and by every permission
/// it asks for; Entoli's are offered over a [ToolBridge] as an MCP server of
/// the session, the way [ClaudeCliSession] offers them.
abstract class AcpProvider extends CliProvider {
  const AcpProvider(
    super.config, {
    super.guest,
    this.bindBridge = McpToolBridge.bind,
  });

  /// How a session offers Entoli's tools to it.
  final BindToolBridge bindBridge;

  /// What starts the program as an ACP agent on its stdio, for [spec].
  List<String> acpArguments(CliSessionSpec spec);

  /// The variables a session for [spec] runs with, beside [environment].
  Map<String, String> acpEnvironment(CliSessionSpec spec) => const {};

  /// Done before each session starts, in its own folders: a program
  /// configured by file rather than by flag writes its file here.
  Future<void> prepare() async {}

  /// Unread: no such program says whether it is signed in by an exit code,
  /// so [signedIn] asks over the protocol instead.
  @override
  List<String> get statusArguments => const [];

  /// Whether a session opens: an agent that is not signed in refuses
  /// `session/new` with `auth_required`.
  @override
  Future<bool> signedIn() async {
    final session =
        await AcpSession.start(
          this,
          CliSessionSpec(model: "", system: "", tools: const []),
        ).then<AcpSession?>((s) => s).catchError((Object e) {
          if (e is! AcpRefused || !e.unauthorized) {
            logFailure("cli", "asking ${config.displayName} its sign-in", e);
          }
          return null;
        });
    await session?.close();
    return session != null;
  }

  /// By the protocol's `logout` where the program offers it, else by its
  /// [signOutArguments] where it has any; a program with neither keeps its
  /// sign-in in [dataDirectory], which Sign in again then starts over.
  ///
  /// A sign-in that outlives all three is somewhere Entoli does not keep it,
  /// the system's credential store, and is said rather than left for Sign
  /// in again to find signed in.
  @override
  Future<void> signOut() async {
    try {
      if (await AcpSession.logOut(this)) return;
    } catch (e) {
      logFailure("cli", "signing ${config.displayName} out by the protocol", e);
    }
    if (signOutArguments.isNotEmpty) return super.signOut();
    await forget();
    if (await signedIn()) {
      throw LlmException(
        "${config.displayName} is still signed in from the system's "
        "credential store. Sign it out there, or with /logout in $command.",
      );
    }
  }

  @override
  List<String> get signOutArguments => const [];

  @override
  Future<CliSession> start(CliSessionSpec spec) => AcpSession.start(this, spec);
}

/// A JSON-RPC error an ACP agent answered with.
class AcpRefused extends LlmException {
  const AcpRefused(super.message, this.code);

  /// [error], a JSON-RPC error object from [name]; `auth_required` said as
  /// what to do about it.
  factory AcpRefused.of(Object? error, String name) {
    final code = error is Map ? (error["code"] as num?)?.toInt() : null;
    final message = error is Map ? "${error["message"]}" : "$error";
    return AcpRefused(
      code == _authRequired
          ? "$name is not signed in. Sign it in again."
          : message,
      code,
    );
  }

  static const _authRequired = -32000;

  final int? code;

  /// ACP's `auth_required`.
  bool get unauthorized => code == _authRequired;
}

/// One ACP agent and the one session it holds.
///
/// A prompt turn runs from `session/prompt` to its response, and a reply
/// ends where the agent calls Entoli's tools over the bridge: the calls are
/// the reply's, the agent waits on each, and the next step's results answer
/// them. Calls that arrive together are one reply; one that arrives after
/// its reply was handed on goes out with the next.
class AcpSession extends CliProcessSession {
  AcpSession._(super.spec, super.name);

  late final String _session;
  ToolBridge? _bridge;

  /// What the agent said it takes, from `initialize`.
  var _capabilities = const <String, dynamic>{};

  /// Whether the system text went in with the session, rather than in front
  /// of the first prompt.
  var _systemSent = false;

  /// Whether a prompt turn is open.
  var _turnOpen = false;

  final _text = StringBuffer();
  final _reasoning = StringBuffer();
  LlmUsage? _usage;

  /// Calls the agent made that no reply has carried yet.
  final _queued = <_Call>[];

  /// Calls handed to the loop, by id, waiting on its results.
  final _reported = <String, HeldToolCall>{};

  /// What makes this session's call ids its own: the loop keys sub-agents
  /// and jobs by a call's id, and a chat outlives its sessions.
  final _tag = _randomTag();
  var _nextCall = 0;
  var _nextId = 0;

  /// Text the agent streamed after its calls were handed out: the bridge and
  /// stdout are two channels, so a chunk written before a call can be read
  /// after it. Said at the head of the next reply.
  final _late = <LlmChunk>[];

  static String _randomTag() {
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    final random = Random.secure();
    return String.fromCharCodes([
      for (var i = 0; i < 8; i++)
        digits.codeUnitAt(random.nextInt(digits.length)),
    ]);
  }

  /// How long a request other than a prompt is waited on: a program that
  /// will not answer `initialize` would otherwise hold a sign-in check open.
  static const _answerWithin = Duration(seconds: 60);
  final _waiting = <int, Completer<Object?>>{};

  static Future<AcpSession> start(AcpProvider provider, CliSessionSpec spec) {
    // Looked for now, so a program that is not there fails the start with
    // where it was looked for.
    provider.executable();
    final session = AcpSession._(spec, provider.config.displayName);
    return opened(provider, session, () async {
      final cwd = await provider.workDirectory();
      await provider.prepare();
      await session.run(
        provider,
        provider.acpArguments(spec),
        environment: provider.acpEnvironment(spec),
      );
      await session._initialize();
      await session._open(provider, cwd);
    });
  }

  /// Signs [provider]'s program out by the protocol, where it offers that:
  /// true where it did.
  static Future<bool> logOut(AcpProvider provider) async {
    provider.executable();
    final session = AcpSession._(
      CliSessionSpec(model: "", system: "", tools: const []),
      provider.config.displayName,
    );
    try {
      await session.run(provider, provider.acpArguments(session.spec));
      await session._initialize();
      final auth = session._capabilities["auth"];
      if (auth is! Map || auth["logout"] == null) return false;
      await session._request("logout", const {});
      return true;
    } finally {
      await session.close();
    }
  }

  Future<void> _initialize() async {
    final result = await _request("initialize", {
      "protocolVersion": 1,
      // No file system and no terminal of Entoli's: its tools are the only
      // way out, and they arrive over MCP.
      "clientCapabilities": const <String, dynamic>{},
      "clientInfo": {"name": "entoli", "title": "Entoli", "version": "1"},
    });
    final capabilities = result is Map ? result["agentCapabilities"] : null;
    if (capabilities is Map<String, dynamic>) _capabilities = capabilities;
  }

  Map<String, dynamic> _capability(String name) =>
      switch (_capabilities[name]) {
        final Map<String, dynamic> map => map,
        _ => const {},
      };

  Future<void> _open(AcpProvider provider, String cwd) async {
    final tools = spec.tools;
    if (tools.isNotEmpty && _capability("mcpCapabilities")["http"] != true) {
      throw LlmException(
        "$name cannot reach Entoli's tools: it takes no MCP server over HTTP",
      );
    }
    final bridge = tools.isEmpty
        ? null
        : await provider.bindBridge(tools, _held);
    _bridge = bridge;
    final prompt = _capability("sessionCapabilities")["systemPrompt"];
    final override = prompt is Map && prompt["mode"] is Map
        ? (prompt["mode"] as Map).containsKey("override")
        : false;
    _systemSent = prompt != null && spec.system.isNotEmpty;
    final opened = await _request("session/new", {
      "cwd": cwd,
      "mcpServers": [if (bridge != null) serverOf(bridge.config)],
      if (_systemSent)
        "systemPrompt": {
          "mode": override ? "override" : "append",
          "content": [
            {"type": "text", "text": spec.system},
          ],
        },
    });
    if (opened is! Map || opened["sessionId"] is! String) {
      throw LlmException("$name opened no session");
    }
    _session = opened["sessionId"] as String;
    if (spec.model.isNotEmpty) await _pick(opened, "model", spec.model);
    if (effortOf(spec.reasoningEffort) case final effort?) {
      await _pick(opened, "thought_level", effort, required: false);
    }
  }

  /// [value] chosen for the session's option of [category]: by its config
  /// options where it has them, else by the older `models` and
  /// `session/set_model` for a model. Where nothing offers it, a [required]
  /// choice fails the session saying what is offered, and any other is left
  /// to the agent.
  Future<void> _pick(
    Map<dynamic, dynamic> opened,
    String category,
    String value, {
    bool required = true,
  }) async {
    final options = opened["configOptions"];
    final option = options is List
        ? options
              .whereType<Map<dynamic, dynamic>>()
              .where((o) => o["category"] == category)
              .firstOrNull
        : null;
    if (option != null) {
      final values = [
        for (final choice
            in (option["options"] as List?)
                    ?.whereType<Map<dynamic, dynamic>>() ??
                const <Map<dynamic, dynamic>>[])
          "${choice["value"]}",
      ];
      if (option["currentValue"] == value) return;
      if (values.contains(value)) {
        await _request("session/set_config_option", {
          "sessionId": _session,
          "configId": option["id"],
          "value": value,
        });
        return;
      }
      if (required) _refuse(category, value, values);
      return;
    }
    final models = opened["models"];
    if (category != "model" || models is! Map) {
      if (required) {
        logFailure("llm", "$name offers no choice of $category");
      }
      return;
    }
    if (models["currentModelId"] == value) return;
    final ids = [
      for (final model
          in (models["availableModels"] as List?)
                  ?.whereType<Map<dynamic, dynamic>>() ??
              const <Map<dynamic, dynamic>>[])
        "${model["modelId"]}",
    ];
    if (!ids.contains(value)) _refuse(category, value, ids);
    await _request("session/set_model", {
      "sessionId": _session,
      "modelId": value,
    });
  }

  Never _refuse(String category, String value, List<String> offered) =>
      throw LlmException(
        "$name offers no $category $value. It offers ${offered.join(", ")}.",
      );

  /// A bridge's `mcpServers` entry as ACP takes one: named, and its headers
  /// a list of name and value.
  static Map<String, dynamic> serverOf(Map<String, dynamic> config) => {
    "type": "http",
    "name": McpToolRoutes.serverName,
    "url": config["url"],
    "headers": [
      for (final MapEntry(:key, :value)
          in (config["headers"] as Map? ?? const {}).entries)
        {"name": "$key", "value": "$value"},
    ],
  };

  @override
  List<String> get held => [..._reported.keys];

  @override
  bool takes(List<LlmMessage> rest) => !_turnOpen && super.takes(rest);

  @override
  void answer(List<LlmMessage> results) {
    final out = current!;
    for (final chunk in _late) {
      out.add(chunk);
    }
    _late.clear();
    for (final result in results) {
      _reported.remove(result.toolCallId)!.answer(result);
    }
    _handOutSoon();
  }

  @override
  void begin(List<LlmMessage> rest) {
    _turnOpen = true;
    _request("session/prompt", {
      "sessionId": _session,
      "prompt": _prompt(rest),
    }).then(
      _turnEnded,
      onError: (Object e) {
        _turnEnded(null);
        end(error: e);
      },
    );
  }

  /// [rest] as a prompt's content. A fresh session handed a history is told
  /// it as a transcript, with the trailing user turns as themselves; the
  /// system text goes first where the session could not take it.
  List<Map<String, dynamic>> _prompt(List<LlmMessage> rest) {
    final (:history, :tail) = splitTail(rest);
    final images = _capability("promptCapabilities")["image"] == true;
    Map<String, dynamic> text(String text) => {"type": "text", "text": text};
    final system = !_systemSent && spec.system.isNotEmpty;
    _systemSent = true;
    return [
      if (system) text("<system>\n${spec.system}\n</system>"),
      if (history.isNotEmpty) text(transcriptOf(history)),
      for (final message in tail) ...[
        text(inlineText(message)),
        for (final file in message.attachments)
          if (file.isImage && images)
            {"type": "image", "mimeType": file.mimeType, "data": file.base64}
          else if (file.isBlock)
            text("(attached: ${file.filename}, ${file.mimeType})"),
      ],
      if (tail.isEmpty) text(carryOn),
    ];
  }

  @override
  void line(Map<String, dynamic> message) {
    final method = message["method"] as String?;
    final id = message["id"];
    final params = message["params"];
    if (method == null) {
      _answered(id, message);
    } else if (id != null) {
      _asked(id, method, params is Map<String, dynamic> ? params : const {});
    } else if (method == "session/update" && params is Map) {
      final update = params["update"];
      if (update is Map<String, dynamic>) _updated(update);
    }
  }

  void _answered(Object? id, Map<String, dynamic> message) {
    final waiting = _waiting.remove(id);
    if (waiting == null) return;
    final error = message["error"];
    if (error != null) {
      waiting.completeError(AcpRefused.of(error, name));
    } else {
      waiting.complete(message["result"]);
    }
  }

  /// A request from the agent. A permission is for one of its own tools —
  /// Entoli's are let through by the subclass's flags — and is refused;
  /// anything else is not Entoli's to answer, there being nobody to ask.
  void _asked(Object id, String method, Map<String, dynamic> params) {
    if (method == "session/request_permission") {
      final options = params["options"];
      final reject = options is List
          ? options
                .whereType<Map<dynamic, dynamic>>()
                .where(
                  (o) =>
                      o["kind"] == "reject_once" ||
                      o["kind"] == "reject_always",
                )
                .firstOrNull
          : null;
      write({
        "jsonrpc": "2.0",
        "id": id,
        "result": {
          "outcome": reject == null
              ? {"outcome": "cancelled"}
              : {"outcome": "selected", "optionId": reject["optionId"]},
        },
      });
      return;
    }
    write({
      "jsonrpc": "2.0",
      "id": id,
      "error": {"code": -32601, "message": "Entoli does not answer $method"},
    });
  }

  void _updated(Map<String, dynamic> update) {
    switch (update["sessionUpdate"]) {
      case "agent_message_chunk":
        if (_textOf(update) case final text?) {
          _say(_text, text, LlmTextChunk.new);
        }
      case "agent_thought_chunk":
        if (_textOf(update) case final text?) {
          _say(_reasoning, text, LlmReasoningChunk.new);
        }
      case "usage_update":
        // What the conversation fills of the window, which is what
        // compaction reads a reply's input as.
        if (update["used"] case final num used) {
          _usage = LlmUsage(inputTokens: used.toInt(), outputTokens: 0);
        }
    }
  }

  static String? _textOf(Map<String, dynamic> update) =>
      switch (update["content"]) {
        {"type": "text", "text": final String text} => text,
        _ => null,
      };

  /// Adds [delta] to [said] and streams it, where an exchange is open; held
  /// for the next where the turn is still open on calls handed out. Output
  /// with no turn open is the agent going on without Entoli's loop, and what
  /// it holds is no longer the conversation the loop has.
  void _say(StringBuffer said, String delta, LlmChunk Function(String) chunk) {
    final out = current;
    said.write(delta);
    if (out != null) return out.add(chunk(delta));
    if (_turnOpen && _reported.isNotEmpty) return _late.add(chunk(delta));
    strayed();
  }

  /// A call from the agent over the bridge: queued for the reply it ends.
  void _held(HeldToolCall call) {
    if (!alive) {
      call.fail(HeldToolCall.stopped);
      return;
    }
    _queued.add(_Call("acp_${_tag}_${++_nextCall}", call));
    _handOutSoon();
  }

  /// The prompt turn's end, with its response where it answered one.
  void _turnEnded(Object? result) {
    _turnOpen = false;
    // A turn that ended leaves nothing waiting on its calls.
    for (final call in [for (final c in _queued) c.held, ..._reported.values]) {
      call.fail(HeldToolCall.stopped);
    }
    _queued.clear();
    _reported.clear();
    _late.clear();
    if (result is! Map) return;
    final stop = switch (result["stopReason"]) {
      "max_tokens" => LlmStop.truncated,
      "refusal" => LlmStop.refused,
      "max_turn_requests" || "cancelled" => LlmStop.unfinished,
      _ => LlmStop.answered,
    };
    end(
      last: LlmCompletion(stop: stop, usage: _usage, message: _reply(const [])),
    );
  }

  /// Hands out the calls that have arrived, once whatever else arrived with
  /// them has been read: calls made together are one reply.
  void _handOutSoon() {
    if (current == null) return;
    Timer.run(() {
      if (current == null || _queued.isEmpty) return;
      final calls = [..._queued];
      _queued.clear();
      for (final call in calls) {
        _reported[call.id] = call.held;
      }
      end(
        last: LlmCompletion(
          stop: LlmStop.toolUse,
          usage: _usage,
          message: _reply([
            for (final call in calls)
              LlmToolCall(
                id: call.id,
                name: call.held.name,
                argumentsJson: jsonEncode(call.held.arguments ?? const {}),
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

  Future<Object?> _request(String method, Map<String, dynamic> params) {
    if (!alive) return Future.error(LlmException("$name is gone"));
    final id = ++_nextId;
    final done = Completer<Object?>();
    _waiting[id] = done;
    write({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
    // A prompt turn runs as long as the work does.
    if (method == "session/prompt") return done.future;
    return done.future.timeout(
      _answerWithin,
      onTimeout: () {
        _waiting.remove(id);
        throw LlmException("$name did not answer $method");
      },
    );
  }

  /// Clears what the exchange has said, with it.
  @override
  void end({LlmChunk? last, Object? error}) {
    _text.clear();
    _reasoning.clear();
    _usage = null;
    super.end(last: last, error: error);
  }

  @override
  void gone(String reason) {
    for (final waiting in _waiting.values) {
      waiting.completeError(LlmException(reason));
    }
    _waiting.clear();
  }

  @override
  Future<void> release() async {
    for (final call in [for (final c in _queued) c.held, ..._reported.values]) {
      call.fail(HeldToolCall.stopped);
    }
    _queued.clear();
    _reported.clear();
    await _bridge?.close();
  }
}

/// A call the agent made over the bridge, and the id the loop knows it by.
class _Call {
  _Call(this.id, this.held);

  final String id;
  final HeldToolCall held;
}
