import "dart:async";
import "dart:convert";
import "dart:io";

import "package:archive/archive.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/data/chat_share.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";
import "package:agent_chat/ui/chat/widgets/imported_bar.dart";
import "package:agent_chat/ui/incoming_links.dart";
import "package:agent_chat/ui/selection.dart";

import "../harness.dart";

void main() {
  late TestApp app;
  late StreamController<Uri> links;

  setUp(() {
    links = StreamController<Uri>();
    app = TestApp.create(links: links.stream);
  });
  tearDown(() => app.dispose());

  Message said(String text) => Message(
    id: "m1",
    role: MessageRole.user,
    createdAt: DateTime.utc(2026, 1, 1),
    parts: [MessagePart.text(text: text)],
  );

  /// A chat on disk with one file in its workspace.
  Future<ChatState> written(WidgetTester tester) => io(tester, () async {
    final chat = await app.seedChat(title: "shared");
    await app.writeChat(Chat(state: chat.state, messages: [said("hello")]));
    final file = File(p.join(app.config.workspaceDir(chat.state.id), "a.txt"));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync("from elsewhere");
    return chat.state;
  });

  String fileIn(ChatState chat) =>
      p.join(app.config.workspaceDir(chat.id), "a.txt");

  group("the bar", () {
    Future<ChatState> openImported(WidgetTester tester) async {
      final chat = await written(tester);
      await io(tester, () => app.repo.saveState(chat.copyWith(imported: true)));
      app.container.read(selectedChatIdProvider.notifier).select(chat.id);
      await app.pump(tester, const ChatPage(), settle: false);
      await pumpUntil(tester, find.byType(ImportedBar));
      await settleIo(tester);
      return chat;
    }

    Future<bool> importedNow(WidgetTester tester, ChatState chat) async =>
        (await io(tester, () => app.repo.loadState(chat.id)))!.imported;

    testWidgets("stands in for the composer", (tester) async {
      await openImported(tester);

      expect(find.byType(Composer), findsNothing);
      expect(find.textContaining("make sure you trust it"), findsOneWidget);
    });

    testWidgets("Enable Chat lets it run without the files it came with", (
      tester,
    ) async {
      final chat = await openImported(tester);

      await tester.tap(find.text("Enable Chat"));
      await pumpUntil(tester, find.byType(Composer));
      await settleIo(tester);

      expect(find.byType(ImportedBar), findsNothing);
      expect(await importedNow(tester, chat), isFalse);
      expect(File(fileIn(chat)).existsSync(), isFalse);
    });

    testWidgets("Enable and Import lets it run with them", (tester) async {
      final chat = await openImported(tester);

      await tester.tap(find.text("Enable and Import"));
      await pumpUntil(tester, find.byType(Composer));
      await settleIo(tester);

      expect(await importedNow(tester, chat), isFalse);
      expect(File(fileIn(chat)).readAsStringSync(), "from elsewhere");
    });
  });

  group("a shared chat link", () {
    /// [link] arriving, waited on until [done]: the import is real file I/O
    /// that draws nothing while it runs.
    Future<void> arrive(
      WidgetTester tester,
      String link, {
      required bool Function() done,
    }) async {
      await app.pump(
        tester,
        const IncomingLinks(child: Scaffold(body: Text("chat"))),
      );
      links.add(Uri.parse(link));
      for (var i = 0; i < 500 && !done(); i++) {
        await io(tester, () => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      await settleIo(tester);
    }

    bool opened() => app.container.read(selectedChatIdProvider) != null;

    bool says(String text) => find.text(text).evaluate().isNotEmpty;

    Future<String> linkTo(WidgetTester tester, ChatState chat) async =>
        (await io(
          tester,
          () => packShare(app.config, chat.id, workspace: {"a.txt"}),
        )).link!;

    testWidgets("is a new imported chat, opened", (tester) async {
      final source = await written(tester);

      await arrive(tester, await linkTo(tester, source), done: opened);

      final id = app.container.read(selectedChatIdProvider);
      expect(id, isNot(source.id));
      final imported = await io(tester, () => app.repo.loadState(id!));
      expect(imported!.imported, isTrue);
      expect(imported.title, "shared");
      expect(
        File(p.join(app.config.workspaceDir(id!), "a.txt")).existsSync(),
        isTrue,
      );
    });

    testWidgets("through the app's own scheme is the same", (tester) async {
      final source = await written(tester);
      final payload = Uri.parse(await linkTo(tester, source)).fragment;

      await arrive(tester, "entoli://share?def=$payload", done: opened);

      final id = app.container.read(selectedChatIdProvider);
      expect(id, isNot(source.id));
      expect(
        (await io(tester, () => app.repo.loadState(id!)))!.imported,
        isTrue,
      );
    });

    testWidgets("cut short says so and imports nothing", (tester) async {
      final source = await written(tester);
      final link = await linkTo(tester, source);

      const cutShort = "This shared chat's link arrived cut short.";

      await arrive(
        tester,
        link.substring(0, link.length - 40),
        done: () => says(cutShort),
      );

      expect(find.text(cutShort), findsOneWidget);
      expect(app.container.read(selectedChatIdProvider), isNull);
      final chats = await io(tester, () => app.repo.listChats());
      expect(chats.map((c) => c.id), [source.id]);
    });

    testWidgets("whose zip holds no chat says so", (tester) async {
      final zip = ZipEncoder().encodeBytes(
        Archive()..add(ArchiveFile.string("a.txt", "hello")),
      );

      const noChat = "This link does not hold a shared chat.";

      await arrive(
        tester,
        "entoli://share?def=${base64Url.encode(zip)}",
        done: () => says(noChat),
      );

      expect(find.text(noChat), findsOneWidget);
      expect(app.container.read(selectedChatIdProvider), isNull);
    });
  });
}
