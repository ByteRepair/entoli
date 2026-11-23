import "package:entoli_core/transcript/handoff.dart";
import "package:entoli_core/transcript/storage.dart";
import "package:entoli_core/model/agent_browser.dart";
import "package:entoli_core/model/file_handoff.dart";
import "package:entoli_core/view/widgets/text_file_page.dart";
import "package:entoli_share_viewer/shared_chat_hand_off.dart";
import "package:file/memory.dart";
import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

/// The file hand-off, counting what it was asked to download.
class _Downloads implements FileHandoff {
  final opened = <String>[];

  @override
  Future<void> open(String path) async => opened.add(path);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Downloads downloads;
  final fs = MemoryFileSystem(style: FileSystemStyle.posix);
  late SharedChatHandOff handOff;

  Future<void> pump(WidgetTester tester) async {
    downloads = _Downloads();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fileHandoffProvider.overrideWithValue(downloads),
          fileSystemProvider.overrideWithValue(fs),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                handOff = SharedChatHandOff(context);
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
  }

  testWidgets("a skill to install says it opens in Entoli", (tester) async {
    await pump(tester);

    await handOff.installSkill("c1", "i1");
    await tester.pump();

    expect(find.text("A skill opens in Entoli."), findsOneWidget);
  });

  testWidgets("the agent's browser says it opens in Entoli", (tester) async {
    await pump(tester);

    await handOff.openBrowser(_NoBrowser(), _Tab());
    await tester.pump();

    expect(find.text("The agent's browser opens in Entoli."), findsOneWidget);
  });

  /// [bytes] as a file in a workspace of the test's own.
  String written(String name, List<int> bytes) {
    final path = p.join("/workspace", name);
    fs.file(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    return path;
  }

  /// The page's read is asynchronous, which a fake clock does not advance,
  /// and its spinner never settles while it runs.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets("a text file opens read only", (tester) async {
    final path = written("notes.txt", "hello notes".codeUnits);
    await pump(tester);

    final opening = handOff.openFile(path);
    await settle(tester);

    expect(find.byType(TextFilePage), findsOneWidget);
    // The bar's actions are drawn once the file is read: More is, Edit not.
    expect(find.byTooltip("More"), findsOneWidget);
    expect(find.text("Edit"), findsNothing);
    expect(find.byTooltip("Edit"), findsNothing);
    Navigator.of(tester.element(find.byType(TextFilePage))).pop();
    await settle(tester);
    await opening;
    expect(downloads.opened, isEmpty);
  });

  testWidgets("a file that is not text downloads", (tester) async {
    final path = written("photo.png", [0x89, 0x50, 0x4e, 0x47, 0, 0, 0xff]);
    await pump(tester);

    final opening = handOff.openFile(path);
    await settle(tester);
    await opening;

    expect(find.byType(TextFilePage), findsNothing);
    expect(downloads.opened, [path]);
  });
}

class _NoBrowser implements AgentBrowser {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Tab implements BrowserTab {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
