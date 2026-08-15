// Not part of `flutter test` (no _test.dart suffix): calls a real provider and
// runs real commands. Run it explicitly, having said where to call:
//
//   MINISWE_BASE_URL=https://ollama.com/v1 \
//   MINISWE_MODEL=kimi-k3 \
//   OLLAMA_API_KEY=... \
//   flutter test test/live/miniswe_live.dart
//
// MINISWE_API is `openai` (the default) or `anthropic`. The key is read from
// MINISWE_API_KEY, or from whichever of the usual variables the base URL
// suggests.
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/miniswe/llm/llm_registry.dart";
import "package:agent_chat/data/miniswe/local_shell.dart";
import "package:agent_chat/data/miniswe/miniswe_agent.dart";
import "package:agent_chat/data/miniswe/miniswe_backend.dart";
import "package:agent_chat/data/prompts/prompt_sources.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";

import "../harness.dart";

const _providerId = "live";

void main() {
  // Deliberately no `TestWidgetsFlutterBinding.ensureInitialized()`: it installs
  // an HttpOverrides that answers every request with a 400, which is the whole
  // of what this file exists to avoid. That rules out `rootBundle`, so the
  // presets are copied off disk below rather than read out of the bundle.
  final env = Platform.environment;
  final baseUrl = env["MINISWE_BASE_URL"] ?? "https://ollama.com/v1";
  final model = env["MINISWE_MODEL"];
  final api = env["MINISWE_API"] == "anthropic" ? LlmApi.anthropic : LlmApi.openai;

  final provider = LlmProviderConfig(
    id: _providerId,
    api: api,
    baseUrl: baseUrl,
    apiKey: env["MINISWE_API_KEY"] ?? "",
    apiKeyEnv: _keyVariableFor(baseUrl),
  );

  Future<(MinisweBackend, AppConfig)> liveBackend() async {
    final config = tempConfig("live_miniswe_");
    _copyPresetsInto(config);
    final library = await PromptLibrary.from([DirectoryPrompts(config)]);
    return (
      MinisweBackend(
        config: config,
        library: library,
        shell: LocalShell(environment: () => const {}),
        // Live means live: it runs what the model asks for.
        options: const MinisweOptions(stepLimit: 12),
        registry: LlmRegistry(
          providers: () => [provider],
          lookupEnv: (name) => Platform.environment[name],
        ),
      ),
      config,
    );
  }

  test("what the endpoint says it can run", () async {
    final (backend, _) = await liveBackend();
    final models = await backend.models();

    stdout.writeln("$baseUrl offers ${models.length} models");
    for (final option in models.take(20)) {
      stdout.writeln("  ${option.modelId}");
    }
    await backend.shutdown();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test("a real turn, through the production path", () async {
    if (model == null) {
      stdout.writeln("Set MINISWE_MODEL to run this. Skipping.");
      return;
    }
    final (backend, config) = await liveBackend();
    final chat = await backend.createChat();
    // A chat gets its directories when it is first saved or first sent to;
    // this drives the backend directly, so it asks for them itself.
    config.ensureChatDirs(chat.state.id);
    File("${config.workspaceDir(chat.state.id).path}/hello.txt")
        .writeAsStringSync("the answer is 42\n");

    final clock = Stopwatch()..start();
    void log(String line) => stdout.writeln("[${clock.elapsedMilliseconds}ms] $line");

    final reply = StringBuffer();
    final thinking = StringBuffer();
    await for (final event in backend.sendPrompt(
      chat.state.id,
      "Read hello.txt in this directory and tell me what it says.",
      model: model,
      provider: _providerId,
      // Nobody is here to answer a banner.
      approveCommands: false,
    )) {
      switch (event) {
        case TextDelta(:final text):
          reply.write(text);
        case ReasoningDelta(:final text):
          thinking.write(text);
        case ReasoningEnd(:final duration):
          log("thought for ${duration?.inSeconds}s");
        case ToolCallEvent(:final call):
          log("bash: ${call.argumentsText}");
        case ToolResultEvent(:final result):
          log("  -> rc=${result.returnCode} ${_oneLine(result.output)}");
        case RetryEvent(:final attempt, :final message):
          log("retry $attempt: $message");
        case ErrorEvent(:final message):
          log("ERROR: $message");
        case ApprovalRequestEvent():
          log("approval asked for (should not happen here)");
        // Nobody is here to pick an answer either, and a turn left waiting on
        // one never ends.
        case QuestionRequestEvent(:final request):
          log("asked ${request.questions.length} question(s), answering nothing");
          await backend.respondQuestions(chat.state.id, request.id,
              List.filled(request.questions.length, null));
        case DoneEvent():
          log("done");
      }
    }

    stdout.writeln("--- reply ---\n$reply");
    if (thinking.isNotEmpty) stdout.writeln("--- thinking ---\n$thinking");

    expect(reply.toString(), contains("42"));
    await backend.shutdown();
  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// The same presets `BundledPrompts` would serve, read from the repository
/// instead of the asset bundle, so the library is real without a binding.
void _copyPresetsInto(AppConfig config) {
  for (final kind in CompletionKind.values) {
    final source = Directory(p.join("assets", "prompts", kind.folder));
    if (!source.existsSync()) continue;
    final target = config.promptsDir(kind);
    if (!target.existsSync()) target.createSync(recursive: true);
    for (final file in source.listSync().whereType<File>()) {
      file.copySync(p.join(target.path, p.basename(file.path)));
    }
  }
}

String _oneLine(String output) {
  final trimmed = output.trim().replaceAll("\n", " ");
  return trimmed.length <= 120 ? trimmed : "${trimmed.substring(0, 120)}…";
}

/// Which variable a given host usually keeps its key in, so the common cases
/// need no MINISWE_API_KEY of their own.
String _keyVariableFor(String baseUrl) {
  if (baseUrl.contains("anthropic.com")) return "ANTHROPIC_API_KEY";
  if (baseUrl.contains("openai.com")) return "OPENAI_API_KEY";
  if (baseUrl.contains("openrouter.ai")) return "OPENROUTER_API_KEY";
  if (baseUrl.contains("groq.com")) return "GROQ_API_KEY";
  return "OLLAMA_API_KEY";
}
