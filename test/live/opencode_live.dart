// Not part of `flutter test` (no _test.dart suffix): spawns a real
// `opencode serve` and talks to a real provider. Run it explicitly:
//   flutter test test/live/opencode_live.dart
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/opencode/opencode_backend.dart";
import "package:agent_chat/data/opencode/real_opencode_transport.dart";
import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/domain/models.dart";

import "../harness.dart";

void main() {
  test("a real turn, through the production path", () async {
    final backend =
        OpencodeBackend(config: tempConfig("live_"), transport: RealOpencodeTransport());
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

  test("what the composer's / and @ menus really get offered", () async {
    final backend =
        OpencodeBackend(config: tempConfig("live_"), transport: RealOpencodeTransport());
    final chat = await backend.createChat();

    for (final kind in CompletionKind.values) {
      for (final option in await backend.completions(chat.state.id, kind)) {
        stdout.writeln("${kind.trigger}${option.name} — ${option.description}");
      }
    }

    await backend.disposeChat(chat.state.id);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
