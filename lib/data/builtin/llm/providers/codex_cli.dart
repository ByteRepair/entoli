import "dart:async";
import "dart:convert";
import "dart:ffi" show Abi;
import "dart:io";

import "package:http/http.dart" as http;
import "package:path/path.dart" as p;

import "../../../../core/log.dart";
import "../../../../domain/llm_provider.dart";
import "../../../../domain/model_info.dart";
import "../llm_client.dart";
import "../openai_client.dart" show inlineText;
import "cli.dart";
import "provider.dart";

/// Codex CLI (`codex`) as a provider: the user's own ChatGPT sign-in
/// answering Entoli's turns.
///
/// A session is one `codex app-server`, Codex's JSON-RPC over stdio, holding
/// one ephemeral thread for a conversation: each step's new message starts a
/// turn on it, and its items stream back as notifications. Codex's own tools
/// are switched off; Entoli's are the thread's dynamic tools, which Codex
/// calls back over the same pipe and waits on until the loop's next step
/// brings the result.
class CodexCliProvider extends CliProvider with OfferedByName {
  const CodexCliProvider([LlmProviderConfig config = preset])
    : this.over(config);

  /// With the process given rather than real: what a test runs a session
  /// over.
  const CodexCliProvider.over(super.config, {super.launch});

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
  String get planName => "ChatGPT";

  @override
  String get serviceName => "ChatGPT";

  @override
  String get connectHint => "Use your ChatGPT plan, through Codex CLI.";

  @override
  String get workFolder => "codex-cli";

  @override
  List<String> get statusArguments => const ["login", "status"];

  /// The ChatGPT sign-in, whose page hands back to a server the program
  /// runs on `localhost:1455` for as long as it waits.
  @override
  List<String> get signInArguments => const ["login"];

  /// OpenAI's newest release on GitHub. The API rather than the page's
  /// redirect: it is what states each asset's SHA-256.
  static final latestUrl = Uri.parse(
    "https://api.github.com/repos/openai/codex/releases/latest",
  );

  @override
  Future<CliRelease?> latestRelease(http.Client client) async {
    final triple = tripleOf(CliProvider.abi);
    if (triple == null) return null;
    final windows = triple.endsWith("windows-msvc");
    final name = windows ? "codex-$triple.exe.zip" : "codex-$triple.tar.gz";
    final release = await LlmProvider.getJson(
      latestUrl,
      headers: const {"Accept": "application/vnd.github+json"},
      httpClient: client,
    );
    final asset = switch (release["assets"]) {
      final List<dynamic> assets =>
        assets
            .whereType<Map<String, dynamic>>()
            .where((a) => a["name"] == name)
            .firstOrNull,
      _ => null,
    };
    if (asset == null) return null;
    final digest = asset["digest"];
    if (digest is! String || !digest.startsWith("sha256:")) {
      throw FormatException("$name has no SHA-256 stated beside it");
    }
    return CliRelease(
      version: "${release["tag_name"]}",
      url: Uri.parse(asset["browser_download_url"] as String),
      sha256: digest.substring("sha256:".length),
      packing: windows ? const ZipProgram() : const TarGzProgram(),
      bytes: asset["size"] as int?,
    );
  }

  /// The target [abi]'s build is named for: musl on Linux, which runs on
  /// either C library; null for a machine OpenAI builds nothing for.
  static String? tripleOf(Abi abi) => switch (abi) {
    Abi.macosArm64 => "aarch64-apple-darwin",
    Abi.macosX64 => "x86_64-apple-darwin",
    Abi.linuxX64 => "x86_64-unknown-linux-musl",
    Abi.linuxArm64 => "aarch64-unknown-linux-musl",
    Abi.windowsX64 => "x86_64-pc-windows-msvc",
    Abi.windowsArm64 => "aarch64-pc-windows-msvc",
    _ => null,
  };

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

  /// Where Codex keeps its config, under [env]: `CODEX_HOME`, or
  /// `~/.codex`. `USERPROFILE` first, as Windows' own home is.
  static String? codexHomeIn(Map<String, String> env) {
    final home = env["USERPROFILE"] ?? env["HOME"];
    return env["CODEX_HOME"] ?? (home == null ? null : p.join(home, ".codex"));
  }

  /// The MCP servers the user's own Codex config declares, which a session
  /// switches off by name: an override cannot empty the table. Read per
  /// session, so an edit to it is picked up by the next.
  static Future<List<String>> userMcpServers(Map<String, String> env) async {
    final home = codexHomeIn(env);
    if (home == null) return const [];
    try {
      return mcpServersIn(
        await File(p.join(home, "config.toml")).readAsString(),
      );
    } on PathNotFoundException {
      return const [];
    } on FileSystemException catch (e) {
      logFailure("llm", "reading Codex's config failed", e);
      return const [];
    }
  }

  /// A TOML bare key: what a table name may be without quotes.
  static const _bareKey = "[A-Za-z0-9_-]+";

  /// The names of the `[mcp_servers.<name>]` tables in [toml], each once.
  static List<String> mcpServersIn(String toml) => {
    for (final m in RegExp(
      '^\\s*\\[\\s*mcp_servers\\.(?:"([^"]+)"|($_bareKey))',
      multiLine: true,
    ).allMatches(toml))
      (m[1] ?? m[2])!,
  }.toList();

  /// [name] as a TOML key: bare where it may be, quoted where not.
  static String _tomlKey(String name) =>
      RegExp("^$_bareKey\$").hasMatch(name) ? name : jsonEncode(name);

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
        "mcp_servers.${_tomlKey(name)}.enabled=false",
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
class CodexCliSession extends CliProcessSession {
  CodexCliSession._(CliSessionSpec spec) : super(spec, "Codex CLI");

  late final String _thread;

  /// Whether a Codex turn is open: from `turn/start` to `turn/completed`.
  var _turnOpen = false;

  /// What the exchange in progress has said so far.
  final _text = StringBuffer();
  final _reasoning = StringBuffer();
  LlmUsage? _usage;

  /// Calls Codex made that no reply has carried yet.
  final _queued = <_Call>[];

  /// The requests of calls handed to the loop, by call id, waiting on its
  /// results.
  final _reported = <String, Object>{};

  var _nextId = 0;
  final _waiting = <int, Completer<Object?>>{};

  static Future<CodexCliSession> start(
    CodexCliProvider provider,
    CliSessionSpec spec,
  ) async {
    final executable = provider.executable();
    final env = provider.environment;
    final cwd = await provider.workDirectory();
    final arguments = CodexCliProvider.argumentsFor(
      await CodexCliProvider.userMcpServers(env),
    );
    final session = CodexCliSession._(spec);
    return opened(provider, session, () async {
      await session.run(
        provider,
        executable,
        arguments,
        workingDirectory: cwd,
        environment: env,
      );
      await session._open(cwd);
    });
  }

  Future<void> _open(String cwd) async {
    await _request("initialize", {
      "clientInfo": {"name": "entoli", "title": "Entoli", "version": "1"},
      // Dynamic tools are an experimental field.
      "capabilities": {"experimentalApi": true},
    });
    write({"method": "initialized"});
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
  List<String> get held => [..._reported.keys];

  @override
  bool takes(List<LlmMessage> rest) => !_turnOpen && super.takes(rest);

  @override
  void answer(List<LlmMessage> results) {
    for (final result in results) {
      _respond(_reported.remove(result.toolCallId)!, _resultOf(result));
    }
    _handOutSoon();
  }

  @override
  void begin(List<LlmMessage> rest) {
    _turnOpen = true;
    _request("turn/start", {
      "threadId": _thread,
      "input": _input(rest),
      "effort": ?effortOf(spec.reasoningEffort),
      "summary": "auto",
    }).catchError((Object e) {
      _turnOpen = false;
      end(error: e);
      return null;
    });
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
            {"type": "image", "url": file.dataUrl}
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
        if (file.isImage) {"type": "inputImage", "imageUrl": file.dataUrl},
    ],
    "success": true,
  };

  @override
  void line(Map<String, dynamic> message) {
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
      write({
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
    final out = current;
    if (out == null) return strayed();
    said.write(delta);
    out.add(chunk(delta));
  }

  void _turnCompleted(Map<dynamic, dynamic> turn) {
    _turnOpen = false;
    // A turn that ended leaves nothing waiting on its calls.
    for (final request in [
      for (final c in _queued) c.request,
      ..._reported.values,
    ]) {
      _respond(request, _failed);
    }
    _queued.clear();
    _reported.clear();
    final status = turn["status"];
    if (status == "completed") {
      end(
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
    end(
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
    if (current == null) return;
    Timer.run(() {
      if (current == null || _queued.isEmpty) return;
      final calls = [..._queued];
      _queued.clear();
      for (final call in calls) {
        _reported[call.id] = call.request;
      }
      end(
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
    if (!alive) return Future.error(const LlmException("Codex CLI is gone"));
    final id = ++_nextId;
    final done = Completer<Object?>();
    _waiting[id] = done;
    write({"id": id, "method": method, "params": params});
    return done.future;
  }

  void _respond(Object id, Map<String, dynamic> result) =>
      write({"id": id, "result": result});

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
}

/// A call Codex made and holds open: the request to answer, and what it is.
class _Call {
  _Call(this.request, this.id, this.name, this.arguments);

  final Object request;
  final String id;
  final String name;
  final Object? arguments;
}
