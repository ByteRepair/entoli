// Not part of `flutter test` (no _test.dart suffix): spawns a real
// `opencode serve` and talks to a real provider. Run it explicitly:
//   flutter test test/live/opencode_live.dart
import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/opencode/opencode_backend.dart";
import "package:agent_chat/data/opencode/opencode_config_dir.dart";
import "package:agent_chat/data/opencode/real_opencode_transport.dart";
import "package:agent_chat/data/prompts/prompt_sources.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";

import "../harness.dart";

void main() {
  /// A backend wired the way the app wires one: a throwaway config directory
  /// holding the app's own commands and agents, and nothing of the user's.
  Future<(OpencodeBackend, AppConfig)> liveBackend() async {
    final config = tempConfig("live_");
    final library = await PromptLibrary.from([
      const BundledPrompts(),
      DirectoryPrompts(config),
    ]);
    writeOpencodeConfig(library, opencodeConfigDir(config));
    return (
      OpencodeBackend(
        config: config,
        transport: RealOpencodeTransport(environment: () => opencodeEnvironment(config)),
      ),
      config,
    );
  }

  test("a real turn, through the production path", () async {
    final (backend, _) = await liveBackend();
    final chat = await backend.createChat();

    final clock = Stopwatch()..start();
    void log(String line) => stdout.writeln("[${clock.elapsedMilliseconds}ms] $line");

    log("sending");
    await for (final event in backend.sendPrompt(
      chat.state.id,
      "say hi",
      model: "glm-5.2",
      provider: "ollama-cloud",
    )) {
      log(switch (event) {
        TextDelta(:final text) => "TextDelta ${text.length} chars",
        ReasoningDelta(:final text) => "ReasoningDelta ${text.length} chars",
        ReasoningEnd(:final duration) => "ReasoningEnd after $duration",
        ErrorEvent(:final message) => "ErrorEvent: $message",
        RetryEvent(:final attempt, :final message) => "Retry #$attempt: $message",
        ToolCallEvent(:final call) => "ToolCall ${call.name}",
        ToolResultEvent() => "ToolResult",
        ApprovalRequestEvent() => "ApprovalRequest",
        DoneEvent() => "Done",
      });
    }
    log("stream closed");

    await backend.disposeChat(chat.state.id);
  }, timeout: const Timeout(Duration(minutes: 4)));

  test("a real server offers agent-chat's commands and agents, not the user's", () async {
    final (backend, config) = await liveBackend();
    final chat = await backend.createChat();
    final url = await backend.transport.ensureServer(
        chat.state.id, config.workspaceDir(chat.state.id).path);

    for (final (path, kind) in [("/command", CompletionKind.command), ("/agent", CompletionKind.agent)]) {
      final response = await HttpClient()
          .getUrl(url.resolve(path))
          .then((r) => r.close())
          .then((r) => r.transform(utf8.decoder).join());
      final names = (jsonDecode(response) as List)
          .map((e) => (e as Map<String, dynamic>)["name"])
          .toList()
        ..sort();
      stdout.writeln("$path: $names");
      // Everything left is opencode's own built-ins.
      stdout.writeln("  ours: ${[for (final d in (await PromptLibrary.from([
            const BundledPrompts(),
            DirectoryPrompts(config)
          ])).entries(kind)) d.name]}");
    }

    await backend.disposeChat(chat.state.id);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
