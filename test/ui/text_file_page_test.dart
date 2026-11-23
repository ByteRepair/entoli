import "dart:io";

import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:re_editor/re_editor.dart";

import "package:entoli_chat/domain/workspace.dart";
import "package:entoli_chat/ui/chat/widgets/markdown_text.dart";
import "package:entoli_chat/ui/widgets/document_view.dart";
import "package:entoli_chat/ui/widgets/text_file_page.dart";
import "package:entoli_chat/ui/workspace/workspace_page.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late TestApp app;
  late String root;

  void start({FakeFileHandoff? handoff}) {
    app = TestApp.create(handoff: handoff);
    root = app.config.projectWorkspaceDir();
    Directory(root).createSync(recursive: true);
  }

  tearDown(() {
    app.dispose();
    DocumentReading.wrap.value = false;
    DocumentReading.textScale.value = 1;
  });

  File seed(String name, [String? text]) =>
      File("$root/$name")..writeAsStringSync(text ?? "contents of $name");

  Future<void> view(
    WidgetTester tester,
    String name, {
    bool popsBinary = false,
  }) async {
    await app.pump(
      tester,
      TextFilePage(path: "$root/$name", name: name, popsBinary: popsBinary),
    );
    await settleIo(tester);
  }

  CodeEditor editor(WidgetTester tester) =>
      tester.widget<CodeEditor>(find.byType(CodeEditor));

  CodeLineEditingController text(WidgetTester tester) =>
      editor(tester).controller!;

  Future<void> more(WidgetTester tester, String item) async {
    await tester.tap(find.byTooltip("More"));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item));
    await settleIo(tester);
  }

  testWidgets("is read, not edited, until Edit", (tester) async {
    start();
    seed("main.dart");
    await view(tester, "main.dart");

    expect(editor(tester).readOnly, isTrue);
    expect(text(tester).text, "contents of main.dart");
    await tester.tap(find.byTooltip("Edit"));
    await tester.pump();
    expect(editor(tester).readOnly, isFalse);
    expect(find.byTooltip("Save"), findsOneWidget);
    expect(find.byTooltip("Preview"), findsOneWidget);
  });

  testWidgets("markdown is rendered until Edit", (tester) async {
    start();
    seed("README.md", "# Title");
    await view(tester, "README.md");
    expect(find.byType(MarkdownText), findsOneWidget);
    expect(find.byType(CodeEditor), findsNothing);
  });

  testWidgets("an edit marks the title, is saved back, and leaving with one "
      "unsaved asks", (tester) async {
    start();
    final file = seed("notes.txt");
    await view(tester, "notes.txt");
    await tester.tap(find.byTooltip("Edit"));
    await tester.pump();
    text(tester).text = "changed";
    await tester.pump();
    expect(find.text("notes.txt •"), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text("Discard your changes?"), findsOneWidget);
    await tester.tap(find.text("Cancel"));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip("Save"));
    await settleIo(tester);
    expect(file.readAsStringSync(), "changed");
    expect(find.text("notes.txt"), findsOneWidget);
  });

  testWidgets("Ctrl+S saves while editing", (tester) async {
    start();
    final file = seed("notes.txt");
    await view(tester, "notes.txt");
    await tester.tap(find.byTooltip("Edit"));
    await tester.pump();
    text(tester).text = "typed";
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settleIo(tester);
    expect(file.readAsStringSync(), "typed");
  });

  testWidgets("a file of mixed line breaks is not changed by opening it", (
    tester,
  ) async {
    start();
    seed("mixed.txt", "one\r\ntwo\nthree");
    await view(tester, "mixed.txt");
    await tester.tap(find.byTooltip("Edit"));
    await tester.pump();
    expect(find.text("mixed.txt"), findsOneWidget);
    expect(find.text("mixed.txt •"), findsNothing);
  });

  testWidgets("the More menu wraps lines and copies the text", (tester) async {
    start();
    seed("notes.txt");
    final copied = clipboard(tester);
    await view(tester, "notes.txt");

    await more(tester, "Wrap lines");
    expect(DocumentReading.wrap.value, isTrue);
    expect(editor(tester).wordWrap, isTrue);

    await more(tester, "Copy");
    expect(copied, ["contents of notes.txt"]);
  });

  testWidgets("one past the limit is not shown, only opened or copied", (
    tester,
  ) async {
    final handoff = FakeFileHandoff();
    start(handoff: handoff);
    seed("big.log", "x" * (textViewLimit + 1));
    final copied = clipboard(tester);
    await view(tester, "big.log");

    expect(find.text("Too large to show here"), findsOneWidget);
    expect(find.byType(CodeEditor), findsNothing);
    expect(find.byTooltip("More"), findsNothing);
    expect(find.byTooltip("Edit"), findsNothing);

    await tester.tap(find.text("Copy text"));
    await settleIo(tester);
    expect(copied.single.length, textViewLimit + 1);
    await tester.tap(find.text("Open in another app"));
    await settleIo(tester);
    expect(handoff.opened, ["$root/big.log"]);
  });

  testWidgets("bytes that are not text go to another app from the explorer", (
    tester,
  ) async {
    final handoff = FakeFileHandoff();
    start(handoff: handoff);
    File("$root/data.txt").writeAsBytesSync([0, 1, 2]);
    await app.pump(tester, WorkspacePage(root: root, title: "Chat workspace"));
    await tester.tap(find.text("data.txt"));
    await settleIo(tester);
    expect(find.byType(TextFilePage), findsNothing);
    expect(handoff.opened, ["$root/data.txt"]);
  });

  testWidgets("opened elsewhere, bytes that are not text are said", (
    tester,
  ) async {
    start();
    File("$root/data.txt").writeAsBytesSync([0, 1, 2]);
    await view(tester, "data.txt");
    expect(find.text("That file could not be read"), findsOneWidget);
    expect(find.text("It is not a text file."), findsOneWidget);
    expect(find.text("Try again"), findsOneWidget);
  });
}
