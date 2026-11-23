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

  /// The resource `cat.jpeg` was saved as.
  const cat = "96fa4649-c736-47b5-ac9f-d2f09cf2a4a4-cat.jpeg";

  /// A chat with [text] said in it, `cat.jpeg` attached, `src/main.dart` and
  /// `.env` in its workspace and one artifact titled "Report".
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
        put(p.join(app.config.resourcesDir(id), cat), [1, 2, 3]);
        put(p.join(app.config.workspaceDir(id), "src/main.dart"), [1, 2]);
        put(p.join(app.config.workspaceDir(id), ".env"), [1]);
        put(p.join(app.config.artifactDir(id, "a1"), "index.html"), [1]);
        return chat.state;
      });

  /// Real rounds until [done]: listing and measuring are file I/O and an
  /// isolate, which the fake clock does not advance.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 400 && !done(); i++) {
      await io(
        tester,
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(done(), isTrue, reason: "never came to rest");
  }

  bool shows(Finder finder) => finder.evaluate().isNotEmpty;

  bool measured() =>
      shows(find.text("Workspace")) &&
      !shows(find.textContaining("Measuring the link"));

  /// The dialog open over a page and measured, and what it closed with once
  /// it has.
  Future<String? Function()> open(WidgetTester tester, ChatState chat) async {
    String? closed;
    await app.pump(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => closed = await showDialog<String>(
              context: context,
              builder: (_) => Dialog(child: ShareChatDialog(chat: chat)),
            ),
            child: const Text("open"),
          ),
        ),
      ),
    );
    await tester.tap(find.text("open"));
    await until(tester, measured);
    return () => closed;
  }

  CheckboxListTile tile(WidgetTester tester, String label) =>
      tester.widget<CheckboxListTile>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(CheckboxListTile),
        ),
      );

  bool? ticked(WidgetTester tester, String label) => tile(tester, label).value;

  /// Whether [label] is drawn in the error colour: left out of the link.
  bool red(WidgetTester tester, String label) {
    final context = tester.element(find.text(label));
    return tester.widget<Text>(find.text(label)).style?.color ==
        Theme.of(context).colorScheme.error;
  }

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pump();
    await until(tester, measured);
  }

  Future<void> share(WidgetTester tester) async {
    await tester.tap(find.text("Share"));
    await until(tester, () => !shows(find.byType(ShareChatDialog)));
  }

  Set<String> members(String link) => {
    for (final file in ZipDecoder().decodeBytes(
      shareZipOf(Uri.parse(link).fragment)!,
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

  testWidgets("offers every attachment at once, first, its list closed", (
    tester,
  ) async {
    await open(tester, await written(tester));

    expect(ticked(tester, "Chat Attachments"), isTrue);
    expect(find.text("1 file, 3 B"), findsOneWidget);
    expect(find.text("cat.jpeg"), findsNothing);
    final top = tester.getTopLeft(find.text("Chat Attachments")).dy;
    expect(top, lessThan(tester.getTopLeft(find.text("Artifacts")).dy));

    await tester.tap(find.byTooltip("Show attachments"));
    await tester.pump();

    expect(ticked(tester, "cat.jpeg"), isTrue);
    expect(
      tester.getTopLeft(find.text("cat.jpeg")).dy,
      lessThan(tester.getTopLeft(find.text("Artifacts")).dy),
    );
  });

  testWidgets("ticks and unticks every attachment from the one line", (
    tester,
  ) async {
    await open(tester, await written(tester));
    await tester.tap(find.byTooltip("Show attachments"));
    await tester.pump();

    await tap(tester, "Chat Attachments");
    expect(ticked(tester, "cat.jpeg"), isFalse);
    expect(ticked(tester, "Chat Attachments"), isFalse);

    await tap(tester, "cat.jpeg");
    expect(ticked(tester, "Chat Attachments"), isTrue);
  });

  testWidgets("leaves a secret unticked and says why", (tester) async {
    await open(tester, await written(tester));

    expect(ticked(tester, ".env"), isFalse);
    expect(find.text("Secret or build file"), findsOneWidget);
  });

  testWidgets("narrows to what the search matches, attachments too", (
    tester,
  ) async {
    await open(tester, await written(tester));

    await tester.enterText(find.byType(TextField), "main");
    await tester.pump();

    expect(find.text("src/main.dart"), findsOneWidget);
    expect(find.text("Report"), findsNothing);
    expect(find.text(".env"), findsNothing);
    expect(find.text("Chat Attachments"), findsNothing);

    await tester.enterText(find.byType(TextField), "cat");
    await tester.pump();

    expect(find.text("cat.jpeg"), findsOneWidget);

    await tester.enterText(find.byType(TextField), "nothing like it");
    await tester.pump();

    expect(find.text("No file matches"), findsOneWidget);
  });

  testWidgets("closes with a link carrying what is ticked", (tester) async {
    final chat = await written(tester);
    final closed = await open(tester, chat);

    await tap(tester, "Report");
    await tap(tester, ".env");
    await share(tester);

    final workspace = "projects/default/workspace/chats/${chat.id}";
    final link = closed()!;
    expect(
      members(link),
      containsAll([
        "$workspace/src/main.dart",
        "$workspace/.env",
        "projects/default/chats/${chat.id}/resources/$cat",
      ]),
    );
    expect(members(link).where((m) => m.contains("/artifacts/")), isEmpty);
  });

  testWidgets("unticked attachments stay behind", (tester) async {
    final closed = await open(tester, await written(tester));

    await tap(tester, "Chat Attachments");
    await share(tester);

    expect(members(closed()!).where((m) => m.contains("/resources/")), isEmpty);
  });

  group("past the cap", () {
    /// [written] with a workspace file no zip makes smaller, too big for a
    /// link.
    Future<ChatState> heavy(WidgetTester tester) async {
      final chat = await written(tester);
      final random = Random(1);
      put(p.join(app.config.workspaceDir(chat.id), "big.bin"), [
        for (var i = 0; i < 200 * 1024; i++) random.nextInt(256),
      ]);
      return chat;
    }

    testWidgets("says in red what would be left out, before sharing", (
      tester,
    ) async {
      await open(tester, await heavy(tester));

      expect(red(tester, "big.bin"), isTrue);
      expect(red(tester, "src/main.dart"), isTrue);
      expect(red(tester, "Report"), isFalse);
      expect(red(tester, "Chat Attachments"), isFalse);
      expect(find.textContaining("what is in red is left out"), findsOneWidget);
    });

    testWidgets("updates as things are unticked", (tester) async {
      await open(tester, await heavy(tester));

      await tap(tester, "big.bin");

      expect(red(tester, "src/main.dart"), isFalse);
      expect(find.textContaining("what is in red"), findsNothing);
      expect(find.textContaining("of link."), findsOneWidget);
    });

    testWidgets("shares without what is in red", (tester) async {
      final chat = await heavy(tester);
      final closed = await open(tester, chat);

      await share(tester);

      final link = closed()!;
      expect(link.length, lessThanOrEqualTo(shareLinkMaxLength));
      expect(members(link).where((m) => m.contains("/workspace/")), isEmpty);
      expect(
        members(link),
        contains("projects/default/chats/${chat.id}/artifacts/a1/index.html"),
      );
    });
  });

  testWidgets("too long even bare says so and will not share", (tester) async {
    final random = Random(1);
    final noise = base64.encode([
      for (var i = 0; i < 200 * 1024; i++) random.nextInt(256),
    ]);
    await open(tester, await written(tester, text: noise));

    expect(find.textContaining("Too long to share as a link"), findsOneWidget);
    final button = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text("Share"),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );
    expect(button.onPressed, isNull);
  });
}
