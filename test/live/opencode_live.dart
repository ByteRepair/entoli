// Not part of `flutter test` (no _test.dart suffix): spawns a real
// `opencode serve` and talks to a real provider. Run it explicitly:
//   flutter test test/live/opencode_live.dart
import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/opencode/opencode_backend.dart";
import "package:agent_chat/data/opencode/real_opencode_transport.dart";
import "package:agent_chat/domain/agent_backend.dart";

void main() {
  test("a real turn, through the production path", () async {
    final tmp = Directory.systemTemp.createTempSync("live_");
    final config = AppConfig.forDirectory(tmp);
    Directory(config.chatsDir.path).createSync(recursive: true);

    final transport = RealOpencodeTransport();
    final backend = OpencodeBackend(config: config, transport: transport);
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
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
