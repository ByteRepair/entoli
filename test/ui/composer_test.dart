import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";

import "../fakes.dart";
import "../harness.dart";

void main() {
  late TestApp app;
  final controller = TextEditingController();
  final sent = <String>[];
  final sentAttachments = <List<Attachment>>[];

  setUp(() {
    app = TestApp.create();
    controller.clear();
    sent.clear();
    sentAttachments.clear();
  });
  tearDown(() => app.dispose());
  tearDownAll(controller.dispose);

  Future<void> pump(WidgetTester tester, {EdgeInsets bars = EdgeInsets.zero}) => app.pump(
        tester,
        underSystemBars(
          bars,
          Scaffold(
            body: Composer(
              controller: controller,
              isRunning: false,
              onSend: (text, attachments) {
                sent.add(text);
                sentAttachments.add(attachments);
              },
              onAbort: () {},
            ),
          ),
        ),
      );

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pumpAndSettle();
  }

  /// The names the menu is offering, in order — the descriptions beside them
  /// carry no trigger character.
  List<String> menuItems(WidgetTester tester) => popupLabels(tester)
      .nonNulls
      .where((s) => s.startsWith("/") || s.startsWith("@"))
      .toList();

  testWidgets("typing / offers every command, in name order", (tester) async {
    await pump(tester);
    await type(tester, "/");

    expect(menuItems(tester), ["/init", "/revert", "/review"]);
  });

  testWidgets("typing narrows the menu to what matches", (tester) async {
    await pump(tester);
    await type(tester, "/rev");

    expect(menuItems(tester), ["/revert", "/review"]);
  });

  testWidgets("a query that matches nothing closes the menu", (tester) async {
    await pump(tester);
    await type(tester, "/zzz");

    expect(find.byType(ListView), findsNothing);
  });

  testWidgets("typing @ offers agents instead", (tester) async {
    await pump(tester);
    await type(tester, "@");

    expect(menuItems(tester), ["@build", "@explore"]);
  });

  testWidgets("@ works mid-message, / only at the start", (tester) async {
    await pump(tester);

    await type(tester, "have @exp");
    expect(menuItems(tester), ["@explore"]);

    await type(tester, "see /rev");
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets("tapping an entry completes it and closes the menu", (tester) async {
    await pump(tester);
    await type(tester, "/rev");

    await tester.tap(find.text("/revert"));
    await tester.pumpAndSettle();

    expect(controller.text, "/revert ");
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets("a completed mention keeps what came before it", (tester) async {
    await pump(tester);
    await type(tester, "ask @exp");

    await tester.tap(find.text("@explore"));
    await tester.pumpAndSettle();

    expect(controller.text, "ask @explore ");
  });

  testWidgets("arrows move the highlight and enter takes it", (tester) async {
    await pump(tester);
    await type(tester, "/");

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(controller.text, "/revert ");
    expect(sent, isEmpty);
  });

  testWidgets("the highlight wraps past the end of the list", (tester) async {
    await pump(tester);
    await type(tester, "/");

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(controller.text, "/review ");
  });

  testWidgets("escape closes the menu and hands enter back to the field", (tester) async {
    await pump(tester);
    await type(tester, "/rev");

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ListView), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(controller.text, "/rev");
  });

  // The test harness never turns a key event into typed text, so this can only
  // show that enter was left to the field, not the newline it produces there.
  testWidgets("with no menu open, enter belongs to the field", (tester) async {
    await pump(tester);
    await type(tester, "hello");

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(controller.text, "hello");
    expect(sent, isEmpty);
  });

  testWidgets("ctrl+enter still sends", (tester) async {
    await pump(tester);
    await type(tester, "hello");

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(sent, ["hello"]);
    expect(controller.text, isEmpty);
  });

  Future<void> insertVia(WidgetTester tester, String label) async {
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets("the + button's Commands entry opens the command menu", (tester) async {
    await pump(tester);
    await insertVia(tester, "Commands");

    expect(controller.text, "/");
    expect(menuItems(tester), ["/init", "/revert", "/review"]);
  });

  testWidgets("the + button's Agents entry opens the agent menu", (tester) async {
    await pump(tester);
    await insertVia(tester, "Agents");

    expect(controller.text, "@");
    expect(menuItems(tester), ["@build", "@explore"]);
  });

  testWidgets("a command goes to the start of the message, a mention to the caret",
      (tester) async {
    await pump(tester);
    await type(tester, "look here");

    await insertVia(tester, "Agents");
    expect(controller.text, "look here @");

    await insertVia(tester, "Commands");
    expect(controller.text, "/look here @");
  });

  testWidgets("asking for commands twice does not stack up slashes", (tester) async {
    await pump(tester);
    await insertVia(tester, "Commands");
    await insertVia(tester, "Commands");

    expect(controller.text, "/");
    expect(menuItems(tester), ["/init", "/revert", "/review"]);
  });

  testWidgets("the + button reopens a menu that was dismissed", (tester) async {
    await pump(tester);
    await type(tester, "/");
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ListView), findsNothing);

    await insertVia(tester, "Commands");

    expect(menuItems(tester), ["/init", "/revert", "/review"]);
  });

  testWidgets("an empty library opens no menu", (tester) async {
    app.dispose();
    app = TestApp.create(library: PromptLibrary.empty);
    await pump(tester);
    await type(tester, "/");

    expect(find.byType(ListView), findsNothing);
  });

  testWidgets("the + button's Image and File entries open the chooser", (tester) async {
    await pump(tester);

    await insertVia(tester, "Image");
    await insertVia(tester, "File");

    expect(app.picker.picks, [AttachmentKind.image, AttachmentKind.file]);
    expect(controller.text, isEmpty);
  });

  testWidgets("what was chosen shows above the field and goes out with the message",
      (tester) async {
    app.picker.scripted = [testAttachment("notes.txt")];
    await pump(tester);
    await insertVia(tester, "File");

    expect(find.text("notes.txt"), findsOneWidget);

    await type(tester, "look");
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(sent, ["look"]);
    expect(sentAttachments.single.map((a) => a.filename), ["notes.txt"]);
    expect(find.text("notes.txt"), findsNothing);
  });

  testWidgets("an image shows itself rather than its name", (tester) async {
    app.picker.scripted = [
      testAttachment("shot.png", mimeType: "image/png", bytes: onePixelPng),
    ];
    await pump(tester);
    await insertVia(tester, "Image");

    expect(find.byType(Image), findsOneWidget);
    expect(find.text("shot.png"), findsNothing);
  });

  testWidgets("the X on an attachment drops it", (tester) async {
    app.picker.scripted = [testAttachment("notes.txt"), testAttachment("other.txt")];
    await pump(tester);
    await insertVia(tester, "File");

    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    expect(find.text("notes.txt"), findsNothing);
    expect(find.text("other.txt"), findsOneWidget);
  });

  testWidgets("an attachment on its own is worth sending, nothing at all is not", (tester) async {
    app.picker.scripted = [testAttachment("notes.txt")];
    await pump(tester);

    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);

    await insertVia(tester, "File");
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(sent, [""]);
    expect(sentAttachments.single.map((a) => a.filename), ["notes.txt"]);
  });

  testWidgets("a cancelled chooser attaches nothing", (tester) async {
    await pump(tester);
    await insertVia(tester, "Image");

    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets("the buttons stay clear of the navigation bar", (tester) async {
    const bars = EdgeInsets.only(top: 40, bottom: 48);
    await pump(tester, bars: bars);

    final bar = tester.getRect(find.byType(Composer));
    final send = tester.getRect(find.byTooltip("Send"));
    expect(bar.bottom - send.bottom, greaterThanOrEqualTo(bars.bottom));
    expect(send.top - bar.top, lessThan(bars.top));
  });
}
