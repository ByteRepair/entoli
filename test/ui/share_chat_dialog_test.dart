import "dart:convert";
import "dart:io";
import "dart:math";

import "package:archive/archive.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/domain/chat_share.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/share_chat_dialog.dart";

import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  void put(String path, List<int> bytes) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  /// A chat with [text] said in it, `src/main.dart` and `.env` in its
  /// workspace and one artifact titled "Report".
  Future<ChatState> written(WidgetTester tester, {String text = "hello"}) =>
      io(tester, () async {
        final chat = await app.seedChat(title: "shared");
        final id = chat.state.id;
        await app.writeChat(
          Chat(
            state: chat.state,
            messages: [
              Message(
                id: "m1",
                role: MessageRole.user,
                createdAt: DateTime.utc(2026, 1, 1),
                parts: [MessagePart.text(text: text)],
              ),
              Message(
                id: "m2",
                role: MessageRole.assistant,
                createdAt: DateTime.utc(2026, 1, 1),
                parts: [
                  MessagePart.artifact(
                    artifactId: "a1",
                    title: "Report",
                    entryFile: "index.html",
                  ),
                ],
              ),
            ],
          ),
        );
        put(p.join(app.config.workspaceDir(id), "src/main.dart"), [1, 2]);
        put(p.join(app.config.workspaceDir(id), ".env"), [1]);
        put(p.join(app.config.artifactDir(id, "a1"), "index.html"), [1]);
        return chat.state;
      });

  /// The dialog open over a page, and what it closed with once it has.
  Future<SharePack? Function()> open(
    WidgetTester tester,
    ChatState chat,
  ) async {
    SharePack? closed;
    await app.pump(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => closed = await showDialog<SharePack>(
              context: context,
              builder: (_) => Dialog(child: ShareChatDialog(chat: chat)),
            ),
            child: const Text("open"),
          ),
        ),
      ),
    );
    await tester.tap(find.text("open"));
    await pumpUntil(tester, find.text("Workspace"));
    await settleIo(tester);
    return () => closed;
  }

  bool ticked(WidgetTester tester, String label) => tester
      .widget<CheckboxListTile>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(CheckboxListTile),
        ),
      )
      .value!;

  Future<void> share(WidgetTester tester) async {
    await tester.tap(find.text("Share"));
    for (var i = 0; i < 200 && find.text("Share").evaluate().isNotEmpty; i++) {
      await io(tester, () => Future<void>.delayed(Duration.zero));
      await tester.pump();
      if (find.textContaining("Too long").evaluate().isNotEmpty) break;
    }
    await settleIo(tester);
  }

  Set<String> members(SharePack pack) => {
    for (final file in ZipDecoder().decodeBytes(
      shareZipOf(Uri.parse(pack.link!).fragment)!,
    ))
      if (file.isFile) file.name,
  };

  testWidgets("offers the artifacts by title and the workspace by path", (
    tester,
  ) async {
    await open(tester, await written(tester));

    expect(find.text("Artifacts"), findsOneWidget);
    expect(find.text("Report"), findsOneWidget);
    expect(find.text("src/main.dart"), findsOneWidget);
    expect(ticked(tester, "Report"), isTrue);
    expect(ticked(tester, "src/main.dart"), isTrue);
  });

  testWidgets("leaves a secret unticked and says why", (tester) async {
    await open(tester, await written(tester));

    expect(ticked(tester, ".env"), isFalse);
    expect(find.text("Secret or build file"), findsOneWidget);
  });

  testWidgets("narrows to what the search matches", (tester) async {
    await open(tester, await written(tester));

    await tester.enterText(find.byType(TextField), "main");
    await tester.pump();

    expect(find.text("src/main.dart"), findsOneWidget);
    expect(find.text("Report"), findsNothing);
    expect(find.text(".env"), findsNothing);

    await tester.enterText(find.byType(TextField), "nothing like it");
    await tester.pump();

    expect(find.text("No file matches"), findsOneWidget);
  });

  testWidgets("closes with a link carrying what is ticked", (tester) async {
    final chat = await written(tester);
    final closed = await open(tester, chat);

    await tester.tap(find.text("Report"));
    await tester.tap(find.text(".env"));
    await tester.pump();
    await share(tester);

    final pack = closed()!;
    final workspace = "projects/default/workspace/chats/${chat.id}";
    expect(
      members(pack),
      containsAll(["$workspace/src/main.dart", "$workspace/.env"]),
    );
    expect(members(pack).where((m) => m.contains("/artifacts/")), isEmpty);
  });

  testWidgets("too long even bare says so and stays open", (tester) async {
    final random = Random(1);
    final noise = base64.encode([
      for (var i = 0; i < 200 * 1024; i++) random.nextInt(256),
    ]);
    final closed = await open(tester, await written(tester, text: noise));

    await share(tester);

    expect(find.textContaining("Too long to share as a link"), findsOneWidget);
    expect(find.byType(ShareChatDialog), findsOneWidget);
    expect(closed(), isNull);
  });
}
