import "dart:async";
import "dart:convert";
import "dart:io";

import "package:collection/collection.dart";
import "package:path/path.dart" as p;

import "../../../../core/log.dart";
import "../../../../domain/model_capability.dart";
import "../../../../domain/model_registry.dart";
import "../hosted_models.dart";
import "../llm_client.dart";
import "provider.dart";

/// Another harness's command-line program — Claude CLI, Codex — answering in
/// the model's place. What is configured is the program and the environment
/// it runs with; there is no URL and no key, the program holding its own
/// sign-in.
///
/// This class is the interface, and what every such program shares: finding
/// the executable, its environment, and a [CliClient] that pools sessions so
/// one harness process carries a conversation across the steps of a turn.
/// What a session *is* — a process per call, a long-lived one fed over stdin,
/// a server it talks to — is the subclass's, through [start].
abstract class CliProvider extends LlmProvider with KeyFree {
  const CliProvider(super.config, [super.terms]);

  /// The login shell's `PATH`, set once by `main` when it has been captured:
  /// a desktop launch inherits a `PATH` that misses what the user's profile
  /// adds, which is where a program like `claude` is usually installed. Null
  /// leaves the inherited one.
  static String? loginPath;

  /// What [command] is when the config names none: a bare name, looked up on
  /// `PATH`.
  String get defaultCommand;

  /// The models the program takes by name, offered beside the user's own.
  List<ModelInfo> get knownModels;

  /// Whether this platform can run a program at all. A phone cannot, so a
  /// CLI entry synced onto one offers nothing rather than failing per turn.
  bool get supported =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  String get command {
    final named = config.command?.trim();
    return named == null || named.isEmpty ? defaultCommand : named;
  }

  /// What of the app's own environment [name] is passed on as. All of it,
  /// unless a subclass knows of variables that belong to something else.
  bool inherits(String name, Map<String, String> inherited) => true;

  /// The app's own environment less what [inherits] keeps out, the login
  /// `PATH` over it, and the config's variables over both.
  Map<String, String> get environment => {
    ...inheritedFrom(Platform.environment),
    "PATH": ?loginPath,
    ...config.env,
  };

  /// [inherited] less what [inherits] keeps out.
  Map<String, String> inheritedFrom(Map<String, String> inherited) => {
    for (final MapEntry(:key, :value) in inherited.entries)
      if (inherits(key, inherited)) key: value,
  };

  /// Where the program may be when [command] was left to its default and
  /// `PATH` has none: a copy another app ships, which may move with that
  /// app's updates. None unless a subclass knows of one.
  List<String> get bundledCopies => const [];

  /// [command] as a path to run, or null where there is none: a path is taken
  /// as it is, a bare name is looked for on [environment]'s `PATH`, and the
  /// default name, found nowhere there, is the first of [bundledCopies].
  String? locate() =>
      _onPath() ??
      (config.command?.trim().isNotEmpty == true
          ? null
          : bundledCopies.where((path) => File(path).existsSync()).firstOrNull);

  String? _onPath() {
    final name = command;
    final windows = Platform.isWindows;
    bool runnable(String path) => File(path).existsSync();
    if (p.isAbsolute(name) || name.contains(p.separator)) {
      return runnable(name) ? name : null;
    }
    final env = environment;
    final extensions = windows
        ? ["", ...(env["PATHEXT"] ?? ".EXE;.CMD;.BAT").toLowerCase().split(";")]
        : const [""];
    for (final dir in (env["PATH"] ?? "").split(windows ? ";" : ":")) {
      if (dir.isEmpty) continue;
      for (final ext in extensions) {
        final candidate = p.join(dir, "$name$ext");
        if (runnable(candidate)) return candidate;
      }
    }
    return null;
  }

  /// [locate], or an [LlmException] saying what was not found and where it
  /// was looked for.
  String executable() =>
      locate() ??
      (throw LlmException(
        p.isAbsolute(command)
            ? "$command does not exist"
            : "$command was not found on PATH${bundledCopies.isEmpty ? "" : " or in Claude Desktop"}. "
                  "Install it, or set its path in the provider's settings.",
      ));

  /// A session of the program for [spec], started and ready for its first
  /// [CliSession.exchange].
  Future<CliSession> start(CliSessionSpec spec);

  @override
  LlmClient client(String? apiKey) => CliClient(this);

  @override
  List<ModelInfo> models(ModelCatalog catalog) {
    if (!supported) return const [];
    final own = {for (final m in config.customModels) m.id: m};
    return [...own.values, ...knownModels.where((m) => !own.containsKey(m.id))];
  }

  @override
  List<Model> serve(String id, ModelInfo? info, ModelHost host) => supported
      ? super.serve(
          id,
          info ?? knownModels.where((m) => m.id == id).firstOrNull,
          host,
        )
      : const [];
}

/// What a session is started for: everything the program is told once, on
/// its command line, rather than per message. A call that differs in any of
/// it needs a session of its own.
class CliSessionSpec {
  const CliSessionSpec({
    required this.model,
    required this.system,
    required this.tools,
    this.reasoningEffort,
  });

  final String model;

  /// The leading system messages, joined.
  final String system;
  final List<LlmTool> tools;
  final String? reasoningEffort;

  /// The tools as one string, compared by value: each step builds its
  /// definitions afresh, so two equal schemas are seldom the same map.
  String get toolsKey => jsonEncode([
    for (final t in tools) [t.name, t.description, t.schema],
  ]);

  bool sameAs(CliSessionSpec other) =>
      model == other.model &&
      system == other.system &&
      reasoningEffort == other.reasoningEffort &&
      toolsKey == other.toolsKey;
}

/// One running instance of the program, carrying one conversation.
///
/// It owns whatever the program needs for its life — the process, a server
/// it reaches the tools through, temporary files — and [close] takes all of
/// it down.
abstract class CliSession {
  CliSession(this.spec);

  final CliSessionSpec spec;

  /// False once the program has gone, or the conversation it holds can no
  /// longer be followed: such a session takes no more exchanges.
  bool get alive;

  /// Whether [rest] — the conversation past what this session has already
  /// seen — can be fed to it as it stands. A fresh session takes anything;
  /// one waiting on tool results takes exactly those.
  bool accepts(List<LlmMessage> rest);

  /// One model call: [rest] fed in, the reply streamed out, closed by exactly
  /// one [LlmCompletion]. The session's state is up to date by the time that
  /// completion is delivered. Failures are [LlmException]s on the stream.
  Stream<LlmChunk> exchange(List<LlmMessage> rest);

  /// Ends the program, gracefully where it will go, by force where it will
  /// not, and frees what it held. Safe to call twice.
  Future<void> close();
}

/// An [LlmClient] over a [CliProvider]'s sessions. The agent loop resends the
/// whole conversation every step; this finds the session that has seen all
/// but the newest of it and feeds it only that, so a turn's steps run in one
/// process with the program's own context and cache, and starts a fresh one
/// where none has.
///
/// One client serves the parent agent, its sub-agents and the title call at
/// once, so it holds several sessions, each busy with one call or parked.
class CliClient implements LlmClient {
  CliClient(this.provider);

  final CliProvider provider;

  /// How long a parked session is kept for its conversation's next step.
  static const idleFor = Duration(minutes: 10);

  /// How many parked sessions are kept at most; the oldest goes first.
  static const maxIdle = 4;

  final _idle = <_Parked>[];
  final _live = <CliSession>{};
  var _closed = false;

  @override
  Stream<LlmChunk> stream(
    List<LlmMessage> messages, {
    required String model,
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) async* {
    if (_closed) throw const LlmException("The client was closed");
    final leading = messages.takeWhile((m) => m.role == LlmRole.system);
    final conversation = messages.skip(leading.length).toList();
    final spec = CliSessionSpec(
      model: model,
      system: joinedSystemText(leading.toList()),
      tools: tools,
      reasoningEffort: reasoningEffort,
    );
    var (session, seen) = _take(spec, conversation);
    if (session == null) {
      session = await provider.start(spec);
      seen = 0;
      if (_closed) {
        await session.close();
        throw const LlmException("The client was closed");
      }
    }
    _live.add(session);
    var parked = false;
    try {
      await for (final chunk in session.exchange(conversation.sublist(seen))) {
        if (chunk is LlmCompletion && session.alive) {
          // Parked before it is handed on: a consumer that stops listening
          // once it has the reply must not take the session down with it.
          _park(session, [...conversation, chunk.message]);
          parked = true;
        }
        yield chunk;
      }
    } finally {
      if (!parked) {
        _live.remove(session);
        unawaited(session.close());
      }
    }
  }

  /// A parked session for [spec] whose conversation [conversation] continues,
  /// and how much of it the session has seen.
  (CliSession?, int) _take(CliSessionSpec spec, List<LlmMessage> conversation) {
    for (final parked in _idle.reversed) {
      final seen = parked.seen;
      if (!parked.session.alive ||
          !parked.session.spec.sameAs(spec) ||
          seen.length >= conversation.length) {
        continue;
      }
      var continues = true;
      for (var i = 0; i < seen.length && continues; i++) {
        continues = sameMessage(seen[i], conversation[i]);
      }
      if (!continues) continue;
      final rest = conversation.sublist(seen.length);
      if (!parked.session.accepts(rest)) continue;
      _idle.remove(parked);
      parked.timer.cancel();
      return (parked.session, seen.length);
    }
    return (null, 0);
  }

  void _park(CliSession session, List<LlmMessage> seen) {
    late final _Parked parked;
    parked = _Parked(
      session,
      seen,
      Timer(idleFor, () {
        if (_idle.remove(parked)) _retire(session);
      }),
    );
    _idle.add(parked);
    while (_idle.length > maxIdle) {
      final oldest = _idle.removeAt(0);
      oldest.timer.cancel();
      _retire(oldest.session);
    }
  }

  void _retire(CliSession session) {
    _live.remove(session);
    unawaited(
      session.close().catchError(
        (Object e) => logFailure("llm", "closing a CLI session failed", e),
      ),
    );
  }

  @override
  void close() {
    _closed = true;
    for (final parked in _idle) {
      parked.timer.cancel();
    }
    _idle.clear();
    for (final session in _live.toList()) {
      _retire(session);
    }
  }

  /// Whether [a], which a session saw, is [b] as the loop sends it back. Not
  /// by every field: the loop keeps what it was given, but the reasoning it
  /// keeps is its own and the text may be trimmed, so the ids decide where
  /// there are any.
  static bool sameMessage(LlmMessage a, LlmMessage b) {
    if (a.role != b.role || a.toolCallId != b.toolCallId) return false;
    if (a.role == LlmRole.assistant) {
      return const ListEquality<String>().equals(
            [for (final c in a.toolCalls) c.id],
            [for (final c in b.toolCalls) c.id],
          ) &&
          a.text.trim() == b.text.trim();
    }
    return a.text == b.text;
  }
}

class _Parked {
  _Parked(this.session, this.seen, this.timer);

  final CliSession session;
  final List<LlmMessage> seen;
  final Timer timer;
}

/// [history] written out as text, for a session that starts part-way through
/// a conversation: a program takes a new message, not a past it did not live
/// through, so the past is told to it.
String transcriptOf(List<LlmMessage> history) {
  final out = StringBuffer(
    "The conversation so far, which you are continuing as the assistant. "
    "Tool calls in it were made and answered already; make new ones with "
    "your tools.\n\n<conversation>\n",
  );
  for (final message in history) {
    final files = [
      for (final file in message.attachments) "[attached: ${file.filename}]",
    ].join(" ");
    switch (message.role) {
      case LlmRole.system:
        out.writeln("System: ${message.text}");
      case LlmRole.user:
        out.writeln("User: ${message.text} $files".trimRight());
      case LlmRole.assistant:
        if (message.text.isNotEmpty) out.writeln("Assistant: ${message.text}");
        for (final call in message.toolCalls) {
          out.writeln(
            "Assistant called ${call.name} (${call.id}) with "
            "${call.argumentsJson}",
          );
        }
      case LlmRole.tool:
        out.writeln(
          "Result of ${message.toolCallId}: ${message.text} $files".trimRight(),
        );
    }
    out.writeln();
  }
  out.write("</conversation>");
  return out.toString();
}

/// [json] decoded for comparing two tool inputs by value, null where it does
/// not parse.
Object? decodedArguments(String json) {
  try {
    return jsonDecode(json.isEmpty ? "{}" : json);
  } on FormatException {
    return null;
  }
}

/// What a session needs of the program it runs: its output a line at a
/// time, a way to write to it, and its end. The port a test fakes;
/// [launchProcess] is the real one.
abstract class CliProcess {
  /// Its standard output, one line per event.
  Stream<String> get lines;

  /// Its standard error, as it comes.
  Stream<String> get errors;

  void writeLine(String line);

  /// Closes its standard input, which a program reading it takes as the end.
  Future<void> closeInput();

  Future<int> get exitCode;

  /// SIGTERM, or SIGKILL where [force].
  void kill({bool force = false});
}

/// How a session starts its program.
typedef LaunchCli =
    Future<CliProcess> Function(
      String executable,
      List<String> arguments, {
      required String workingDirectory,
      required Map<String, String> environment,
    });

/// [executable] run as a process of this machine, with [environment] and
/// nothing else of the app's.
Future<CliProcess> launchProcess(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Map<String, String> environment,
}) async => _IoCliProcess(
  await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: false,
    // npm installs a `.cmd` shim on Windows, which only a shell runs.
    runInShell:
        Platform.isWindows &&
        const [".cmd", ".bat"].contains(p.extension(executable).toLowerCase()),
  ),
);

class _IoCliProcess implements CliProcess {
  _IoCliProcess(this._process);

  final Process _process;

  @override
  Stream<String> get lines =>
      _process.stdout.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<String> get errors => _process.stderr.transform(utf8.decoder);

  @override
  void writeLine(String line) => _process.stdin.writeln(line);

  @override
  Future<void> closeInput() => _process.stdin.close();

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void kill({bool force = false}) =>
      _process.kill(force ? ProcessSignal.sigkill : ProcessSignal.sigterm);
}
