import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/core/migrations.dart";
import "package:agent_chat/domain/chat_log.dart";
import "package:agent_chat/domain/models.dart";

import "../harness.dart";

/// 7.5.0, the entry that made the main agent Athena: a log written before it
/// reads as though she had always been named.
void main() {
  final at = DateTime.utc(2026, 1, 1);

  String line(ChatRecord record) => jsonEncode(record.toJson());

  File seed(String dataDir, String relative, List<String> lines) =>
      File(p.joinAll([dataDir, ...relative.split("/")]))
        ..createSync(recursive: true)
        ..writeAsStringSync("${lines.join("\n")}\n");

  test("an unnamed reply is Athena's, and a say to nobody was said to her, "
      "the rest left as it was", () async {
    final config = tempConfig();
    final member = line(
      ChatRecord.message(
        id: "a2",
        role: MessageRole.assistant,
        createdAt: at,
        author: "@build",
      ),
    );
    final addressed = line(
      ChatRecord.message(
        id: "u2",
        role: MessageRole.user,
        createdAt: at,
        addressees: const ["@build"],
      ),
    );
    final end = line(
      const ChatRecord.turnEnd(messageId: "a1", reason: TurnEnd.done),
    );
    final log = seed(config.dataDir, "projects/default/chats/c1/conv.jsonl", [
      line(ChatRecord.message(id: "u1", role: MessageRole.user, createdAt: at)),
      line(
        ChatRecord.message(
          id: "a1",
          role: MessageRole.assistant,
          createdAt: at,
        ),
      ),
      end,
      addressed,
      member,
      "{ the line a kill landed in",
    ]);
    // A user's own file of the same name, in a chat's workspace: not a log.
    final decoy = seed(
      config.dataDir,
      "projects/default/workspace/chats/c1/conv.jsonl",
      [
        line(
          ChatRecord.message(id: "x", role: MessageRole.user, createdAt: at),
        ),
      ],
    );
    final decoyBefore = decoy.readAsStringSync();

    await runMigrations(config.dataDir, fresh: false);

    final lines = log.readAsLinesSync();
    final records = [
      for (final l in lines.take(5)) ChatRecord.fromJson(jsonDecode(l)),
    ];
    expect((records[0] as MessageRecord).addressees, ["@athena"]);
    expect((records[1] as MessageRecord).author, "@athena");
    expect(lines.sublist(2), [
      end,
      addressed,
      member,
      "{ the line a kill landed in",
    ]);
    expect(decoy.readAsStringSync(), decoyBefore);
    expect(File(migrationStamp(config.dataDir)).readAsStringSync(), "7.5.0");
  });

  test("a message's documents become the references they were keyed by, "
      "in the order written, beside what else the entry does", () async {
    final config = tempConfig();
    final log = seed(config.dataDir, "projects/p/chats/c1/conv.jsonl", [
      jsonEncode({
        "runtimeType": "message",
        "id": "u1",
        "role": "user",
        "createdAt": at.toIso8601String(),
        "documents": {
          "/review": "Review the diff.",
          "@explore": "You explore.",
          "@build": "You build.",
        },
        "addressees": ["@explore", "@build"],
      }),
      jsonEncode({
        "runtimeType": "message",
        "id": "a1",
        "role": "assistant",
        "createdAt": at.toIso8601String(),
        "documents": <String, String>{},
      }),
    ]);

    await runMigrations(config.dataDir, fresh: false);

    final lines = log.readAsLinesSync();
    expect(lines.where((l) => l.contains("documents")), isEmpty);
    final said = ChatRecord.fromJson(jsonDecode(lines[0])) as MessageRecord;
    expect(said.references, ["/review", "@explore", "@build"]);
    expect(said.addressees, ["@explore", "@build"]);
    final reply = ChatRecord.fromJson(jsonDecode(lines[1])) as MessageRecord;
    expect(reply.references, isEmpty);
    expect(reply.author, "@athena");
  });
}
