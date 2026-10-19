// Not part of `flutter test` (no _test.dart suffix): calls a real provider and
// runs real commands. Run it explicitly, having said where to call:
//
//   BUILTIN_BASE_URL=https://ollama.com/v1 \
//   BUILTIN_MODEL=kimi-k3 \
//   OLLAMA_API_KEY=... \
//   flutter test test/live/builtin_live.dart
//
// BUILTIN_API is `openai` (the default) or `anthropic`. The key is read from
// BUILTIN_API_KEY, or from whichever of the usual variables the base URL
// suggests.
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/builtin/builtin_agent.dart";
import "package:agent_chat/data/builtin/builtin_backend.dart";
import "package:agent_chat/data/builtin/duckduckgo_search.dart";
import "package:agent_chat/data/builtin/llm/llm_registry.dart";
import "package:agent_chat/data/builtin/local_shell.dart";
import "package:agent_chat/data/local/file_chat_store.dart";
import "package:agent_chat/data/prompts/prompt_sources.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/llm_provider.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/permission.dart";
import "package:agent_chat/domain/prompt_library.dart";

import "../harness.dart";

const _providerId = "live";

void main() {
  // Deliberately no `TestWidgetsFlutterBinding.ensureInitialized()`: it installs
  // an HttpOverrides that answers every request with a 400, which is the whole
  // of what this file exists to avoid. That rules out `rootBundle`, so the
  // presets are copied off disk below rather than read out of the bundle.
  final env = Platform.environment;
  final baseUrl = env["BUILTIN_BASE_URL"] ?? "https://ollama.com/v1";
  final model = env["BUILTIN_MODEL"];
  final api = env["BUILTIN_API"] == "anthropic" ? LlmApi.anthropic : LlmApi.openai;

  final provider = LlmProviderConfig(
    id: _providerId,
    api: api,
    baseUrl: baseUrl,
    // The key reaches the client through the environment lookup below.
    apiKeyEnv: env["BUILTIN_API_KEY"] == null ? null : "BUILTIN_API_KEY",
  );

  Future<(BuiltinBackend, AppConfig)> liveBackend() async {
    final config = tempConfig("live_builtin_");
    _copyPresetsInto(config);
    final library = await PromptLibrary.from([DirectoryPrompts(config)]);
    final backend = BuiltinBackend(
      config: config,
      shell: LocalShell(environment: () => const {}),
      webSearch: DuckDuckGoSearch(),
      store: FileChatStore(config),
      // Live means live: it runs what the model asks for.
      options: const BuiltinOptions(stepLimit: 12),
      registry: LlmRegistry(
        endpoints: () => [LlmEndpoint(provider)],
          lookupEnv: (name) => Platform.environment[name],
          lookupKey: (_) => null,
        ),
    );
    backend.setLibrary(null, library);
    return (backend, config);
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
      stdout.writeln("Set BUILTIN_MODEL to run this. Skipping.");
      return;
    }
    final (backend, config) = await liveBackend();
    final chat = await backend.createChat();
    // A chat gets its directories when it is first saved or first sent to;
    // this drives the backend directly, so it asks for them itself.
    await config.ensureChatDirs(chat.state.id);
    File("${config.workspaceDir(chat.state.id)}/hello.txt")
        .writeAsStringSync("the answer is 42\n");

    final clock = Stopwatch()..start();
    void log(String line) => stdout.writeln("[${clock.elapsedMilliseconds}ms] $line");

    final reply = StringBuffer();
    final thinking = StringBuffer();
    await for (final event in backend.sendPrompt(
      chat.state.id,
      Message(
        id: "u1",
        role: MessageRole.user,
        createdAt: DateTime.now(),
        parts: const [
          MessagePart.text(
              text: "Read hello.txt in this directory and tell me what it says.")
        ],
      ),
      settings: TurnSettings(
        model: model,
        provider: _providerId,
        // Nobody is here to answer a banner.
        approveMode: ApproveMode.never,
      ),
    )) {
      switch (event) {
        case ResponseStart():
          break;
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
        case ShellRunEvent(:final run):
          log("! ${run.command} -> rc=${run.returnCode} ${_oneLine(run.output)}");
        case ShellOutputEvent(:final text):
          log("  … ${_oneLine(text)}");
        case ArtifactEvent(:final title, :final entryFile):
          log("artifact: $title (entry: $entryFile)");
        case SkillInstallEvent(:final title):
          log("skill offered: $title");
        case ImageEvent(:final part):
          log("image: ${part.filename}");
        case RetryEvent(:final attempt, :final message):
          log("retry $attempt: $message");
        // Drawn as a row beside the spinner in the app; here it is one line per
        // change, which against a local model is a running prefill percentage.
        case StatusEvent(:final label):
          if (label != null) log("status: $label");
        case ErrorEvent(:final message):
          log("ERROR: $message");
        case ApprovalRequestEvent():
          log("approval asked for (should not happen here)");
        // Nobody is here to pick an answer either, and a turn left waiting on
        // one never ends.
        case QuestionRequestEvent(:final request):
          log("asked ${request.questions.length} question(s), answering nothing");
          await backend.respondQuestions(chat.state.id, request.id, request.unanswered);
        case SubAgentStartEvent(:final agent):
          log("sub-agent @$agent started");
        case SubAgentEndEvent(:final id, :final failed):
          log("sub-agent $id ${failed ? "failed" : "finished"}");
        case InfoEvent(:final message):
          log("info: $message");
        case StepLimitEvent(:final limit):
          log("step limit: $limit");
        case InstructionsReadEvent(:final files):
          log("instructions: ${files.map((f) => f.path).join(", ")}");
        case ContextEvent(:final usage):
          log("context: ${usage.total} tokens");
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
    final target = Directory(config.promptsDir(kind));
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
