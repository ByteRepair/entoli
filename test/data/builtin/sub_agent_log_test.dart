import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:fs_shim/fs_io.dart" show fileSystemIo;

import "package:agent_chat/core/config.dart";
import "package:agent_chat/data/local/file_sub_agent_log.dart";
import "package:agent_chat/data/builtin/sub_agent.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/domain/shell.dart";

import "../../harness.dart";
import "builtin_fakes.dart";

void main() {
  const chatId = "chat-1";
  late AppConfig config;
  late FileSubAgentLog log;

  setUp(() {
    config = tempConfig("agent_chat_subagent_");
    log = FileSubAgentLog(config, chatId);
  });

  /// What a kill leaves behind: a reply with something in it and no `turnEnd`
  /// record closing the turn.
  Message killedHalfway(String callId, String text) => Message(
        id: callId,
        role: MessageRole.assistant,
        createdAt: DateTime.utc(2026),
        parts: [MessagePart.text(text: text)],
      );

  PromptLibrary libraryWithGeneral() => PromptLibrary([
        PromptDocument.parse(
            CompletionKind.agent, "general", "---\n---\nYou are a general agent."),
      ]);

  SubAgentRunner runnerOver(FakeLlmClient client,
          {ShellResult Function(String)? respond}) =>
      SubAgentRunner(
        client: client,
        shell: FakeShell(respond ?? (_) => ok(""), canRunCommands: true),
        fs: fileSystemIo,
        workspace: config.workspaceDir(chatId),
        projectWorkspace: config.projectWorkspaceDir(),
        model: "fake-model",
        library: libraryWithGeneral(),
        log: log,
      );

  group("a sub-agent's own transcript", () {
    test("is written under the call that spawned it", () async {
      final runner = runnerOver(FakeLlmClient([
        [bashCall("ls")],
        [saidOnly("all done")],
      ]));

      await runner.run("general", "look around", callId: "call-7");

      expect(File(config.subAgentFile(chatId, "call-7")).existsSync(), isTrue);
      final messages = await log.read("call-7");
      expect(messages.single.parts.whereType<ToolCallPart>(), hasLength(1));
      expect(messages.single.plainText, contains("all done"));
    });

    test("nothing is written for a call with no id", () async {
      final runner = runnerOver(FakeLlmClient([
        [saidOnly("done")],
      ]));

      await runner.run("general", "look around");

      expect(Directory(config.subAgentsDir(chatId)).existsSync(), isFalse);
    });

    test("one that finished is not offered to be carried on", () async {
      final runner = runnerOver(FakeLlmClient([
        [saidOnly("done")],
      ]));

      await runner.run("general", "look around", callId: "call-7");

      expect(await log.isResumable("call-7"), isFalse);
    });

    test("one killed mid-turn is, and a missing one is not", () async {
      // What a kill leaves: records with no `turnEnd` closing them.
      await log.append("call-9", recordsOf([killedHalfway("call-9", "halfway")]));

      expect(await log.isResumable("call-9"), isTrue);
      expect(await log.isResumable("never-ran"), isFalse);
    });

    test("carrying one on adds to the transcript it already had", () async {
      await log.append("call-9", recordsOf([killedHalfway("call-9", "halfway")]));

      final runner = runnerOver(FakeLlmClient([
        [saidOnly("and finished")],
      ]));
      final result = await runner.resume("general", "call-9");

      expect(result.returnCode, 0);
      expect(result.output, contains("and finished"));
      // The same message, carried on rather than a second one beside it.
      final messages = await log.read("call-9");
      expect(messages, hasLength(1));
      expect(messages.single.plainText, "halfway\nand finished");
      expect(await log.isResumable("call-9"), isFalse);
    });

    test("what it already did is put back in front of the model", () async {
      await log.append("call-9", recordsOf([killedHalfway("call-9", "I counted three files")]));

      final client = FakeLlmClient([
        [saidOnly("done")],
      ]);
      await runnerOver(client).resume("general", "call-9");

      final sent = client.sent.single;
      expect(sent.any((m) => m.text.contains("I counted three files")), isTrue);
    });
  });
}
