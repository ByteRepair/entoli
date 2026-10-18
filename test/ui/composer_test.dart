import "package:flutter/foundation.dart" show ValueListenable;
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/prompt_library.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";

import "../data/builtin/builtin_fakes.dart";
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

  Future<void> pump(WidgetTester tester,
          {EdgeInsets bars = EdgeInsets.zero,
          String? workspace,
          String? workspaceHome}) =>
      app.pump(
        tester,
        underSystemBars(
          bars,
          Scaffold(
            body: Composer(
              controller: controller,
              agentSpeaking: false,
              onSend: (text, attachments) {
                sent.add(text);
                sentAttachments.add(attachments);
              },
              onAbort: () {},
              workspace: workspace,
              workspaceHome: workspaceHome,
            ),
          ),
        ),
      );

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await settleIo(tester);
  }

  /// The names the menu is offering, in order — the descriptions beside them
  /// carry no trigger character.
  List<String> menuItems(WidgetTester tester) => popupLabels(tester)
      .nonNulls
      .where((s) => s.startsWith("/") || s.startsWith("@"))
      .toList();

  // `/` offers skills and only at the start; `@` offers agents anywhere a word
  // starts. Each in name order, narrowed by what follows; nothing matching is
  // no menu.
  testWidgets("the menu offers what the typed trigger matches", (tester) async {
    await pump(tester);
    for (final (text, offered) in [
      ("/", ["/init", "/revert", "/review"]),
      ("/rev", ["/revert", "/review"]),
      ("/zzz", <String>[]),
      ("@", ["@build", "@explore"]),
      ("have @exp", ["@explore"]),
      ("see /rev", <String>[]),
    ]) {
      await type(tester, text);
      if (offered.isEmpty) {
        expect(find.byType(ListView), findsNothing, reason: text);
      } else {
        expect(menuItems(tester), offered, reason: text);
      }
    }
  });

  testWidgets("tapping an entry completes it and closes the menu", (tester) async {
    await pump(tester);
    await type(tester, "/rev");

    await tester.tap(find.text("/revert"));
    await settleIo(tester);

    expect(controller.text, "/revert ");
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets("a completed mention keeps what came before it", (tester) async {
    await pump(tester);
    await type(tester, "ask @exp");

    await tester.tap(find.text("@explore"));
    await settleIo(tester);

    expect(controller.text, "ask @explore ");
  });

  testWidgets("arrows move the highlight and enter takes it", (tester) async {
    await pump(tester);
    await type(tester, "/");

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleIo(tester);

    expect(controller.text, "/revert ");
    expect(sent, isEmpty);
  });

  testWidgets("the highlight wraps past the end of the list", (tester) async {
    await pump(tester);
    await type(tester, "/");

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleIo(tester);

    expect(controller.text, "/review ");
  });

  testWidgets("escape closes the menu and hands enter back to the field", (tester) async {
    await pump(tester);
    await type(tester, "/rev");

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleIo(tester);
    expect(find.byType(ListView), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleIo(tester);
    expect(controller.text, "/rev");
  });

  // The test harness never turns a key event into typed text, so this can only
  // show that enter was left to the field, not the newline it produces there.
  testWidgets("with no menu open, enter belongs to the field", (tester) async {
    await pump(tester);
    await type(tester, "hello");

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleIo(tester);

    expect(controller.text, "hello");
    expect(sent, isEmpty);
  });

  testWidgets("with no menu open, tab indents the message", (tester) async {
    await pump(tester);
    await type(tester, "hello");

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await settleIo(tester);

    expect(controller.text, "hello  ");
    expect(sent, isEmpty);
  });

  testWidgets("with the menu open, tab still takes the highlight", (tester) async {
    await pump(tester);
    await type(tester, "/rev");

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await settleIo(tester);

    expect(controller.text, "/revert ");
  });

  testWidgets("ctrl+enter still sends", (tester) async {
    await pump(tester);
    await type(tester, "hello");

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settleIo(tester);

    expect(sent, ["hello"]);
    expect(controller.text, isEmpty);
  });

  Future<void> insertVia(WidgetTester tester, String label) async {
    await tester.tap(find.byIcon(Icons.add));
    await settleIo(tester);
    await tester.tap(find.text(label));
    await settleIo(tester);
  }

  testWidgets("the + button's Skills entry opens the skill menu", (tester) async {
    await pump(tester);
    await insertVia(tester, "Skills");

    expect(controller.text, "/");
    expect(menuItems(tester), ["/init", "/revert", "/review"]);
  });

  testWidgets("the + button's Agents entry opens the agent menu", (tester) async {
    await pump(tester);
    await insertVia(tester, "Agents");

    expect(controller.text, "@");
    expect(menuItems(tester), ["@build", "@explore"]);
  });

  testWidgets("a skill goes to the start of the message, a mention to the caret",
      (tester) async {
    await pump(tester);
    await type(tester, "look here");

    await insertVia(tester, "Agents");
    expect(controller.text, "look here @");

    await insertVia(tester, "Skills");
    expect(controller.text, "/look here @");
  });

  testWidgets("asking for skills twice does not stack up slashes", (tester) async {
    await pump(tester);
    await insertVia(tester, "Skills");
    await insertVia(tester, "Skills");

    expect(controller.text, "/");
    expect(menuItems(tester), ["/init", "/revert", "/review"]);
  });

  testWidgets("the + button reopens a menu that was dismissed", (tester) async {
    await pump(tester);
    await type(tester, "/");
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleIo(tester);
    expect(find.byType(ListView), findsNothing);

    await insertVia(tester, "Skills");

    expect(menuItems(tester), ["/init", "/revert", "/review"]);
  });

  // A paired device's library is anybody's: a long name and hint are cut
  // rather than run the row past the menu's edge.
  testWidgets("a long entry fits its row", (tester) async {
    app.dispose();
    app = TestApp.create(library: PromptLibrary([
      PromptDocument(
        kind: CompletionKind.skill,
        name: "a-very-long-skill-name-that-goes-on-and-on-past-any-menu",
        frontmatter: {"description": "d" * 200},
        metadata: {"argument-hint": "<an argument hint just as long as the name>"},
        body: "",
      ),
    ]));
    await pump(tester);
    await type(tester, "/");

    expect(tester.takeException(), isNull);
    expect(menuItems(tester), hasLength(1));
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
    await settleIo(tester);

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
    await settleIo(tester);

    expect(find.text("notes.txt"), findsNothing);
    expect(find.text("other.txt"), findsOneWidget);
  });

  testWidgets("an attachment on its own is worth sending, nothing at all is not", (tester) async {
    app.picker.scripted = [testAttachment("notes.txt")];
    await pump(tester);

    // The button is dead here, so this taps a live pixel that does nothing.
    // `_submit`'s own guard is what Ctrl+Enter still meets.
    await tester.tap(find.byIcon(Icons.send));
    await settleIo(tester);
    expect(sent, isEmpty);

    await insertVia(tester, "File");
    await tester.tap(find.byIcon(Icons.send));
    await settleIo(tester);

    expect(sent, [""]);
    expect(sentAttachments.single.map((a) => a.filename), ["notes.txt"]);
  });

  group("the send button", () {
    Finder send() => find.widgetWithIcon(IconButton, Icons.send);

    testWidgets("is dead until there is something to send, and after it goes",
        (tester) async {
      await pump(tester);
      expect(enabled(tester, send()), isFalse);

      await type(tester, "hello");
      expect(enabled(tester, send()), isTrue);

      await tester.tap(send());
      await settleIo(tester);

      expect(enabled(tester, send()), isFalse);

      // Whitespace counts as nothing too: not worth sending before, not after.
      await type(tester, "   ");
      expect(enabled(tester, send()), isFalse);
    });
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

  group("a message bound for the shell", () {
    InputDecoration decoration(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).decoration!;

    testWidgets("says so from the bang alone, before anything follows it",
        (tester) async {
      await pump(tester);
      await type(tester, "!");

      expect(decoration(tester).hintText, "Shell command");
      expect(find.byIcon(Icons.terminal), findsOneWidget);
      expect(find.byTooltip("Run"), findsOneWidget);
    });

    testWidgets("goes back to a message when the bang does", (tester) async {
      await pump(tester);
      await type(tester, "!ls");
      await type(tester, "ls");

      expect(decoration(tester).hintText, "Message...");
      expect(find.byIcon(Icons.terminal), findsNothing);
      expect(find.byTooltip("Send"), findsOneWidget);
    });

    // Nothing in the menu dispatches inside a command, so offering one would be
    // offering something that does not happen.
    testWidgets("offers no agent to mention", (tester) async {
      await pump(tester);
      await type(tester, "!git commit -m @rev");

      expect(find.byType(ListView), findsNothing);
    });

    testWidgets("is sent as typed, bang and all", (tester) async {
      await pump(tester);
      await type(tester, "!echo hello");
      await tester.tap(find.byTooltip("Run"));
      await settleIo(tester);

      expect(sent, ["!echo hello"]);
    });
  });

  group("where a shell command will run", () {
    const workspace = _ShellWithCwd.starting;

    _ShellWithCwd withBar(WidgetTester tester) {
      final shell = _ShellWithCwd();
      app.dispose();
      app = TestApp.create(shell: shell);
      return shell;
    }

    testWidgets("shows the shell's own directory while a command is being typed",
        (tester) async {
      withBar(tester);
      await pump(tester, workspace: workspace);

      // Nothing outside a command draws it.
      expect(find.text(workspace), findsNothing);

      await type(tester, "!");
      expect(find.text(workspace), findsOneWidget);
    });

    testWidgets("and follows the shell as a command moves it", (tester) async {
      final shell = withBar(tester);
      await pump(tester, workspace: workspace);
      await type(tester, "!");

      shell.cwd.value = "$workspace/sub";
      await tester.pump();

      expect(find.text("$workspace/sub"), findsOneWidget);
    });

    testWidgets("a tap copies the directory out", (tester) async {
      withBar(tester);
      await pump(tester, workspace: workspace);
      await type(tester, "!");

      final copied = clipboard(tester);
      await tester.tap(find.text(workspace));
      await settleIo(tester);

      expect(copied, [workspace]);
    });

    testWidgets("a chat whose session the shell has not heard from is worded in the guest's vocabulary",
        (tester) async {
      app.dispose();
      app = TestApp.create(shell: _MaskedShell());
      await pump(
        tester,
        workspace: "$workspace/chats/x",
        workspaceHome: workspace,
      );
      await type(tester, "!");

      expect(find.text("/root/chats/x"), findsOneWidget);
    });
  });

  group("the keyboard", () {
    testWidgets("comes up when the field is tapped", (tester) async {
      await pump(tester);
      expect(tester.testTextInput.isVisible, isFalse);

      await tester.tap(find.byType(TextField));
      await settleIo(tester);

      expect(tester.testTextInput.isVisible, isTrue);
    });

    // The picker and the menu it opens are both tapped rather than typed at,
    // so there is nothing to bring the keyboard up for.
    testWidgets("stays down for a file that was attached, and for a menu opened from +",
        (tester) async {
      app.picker.scripted = [testAttachment("notes.txt")];
      await pump(tester);
      await insertVia(tester, "File");

      expect(find.text("notes.txt"), findsOneWidget);
      expect(tester.testTextInput.isVisible, isFalse);

      await insertVia(tester, "Skills");

      expect(menuItems(tester), ["/init", "/revert", "/review"]);
      expect(tester.testTextInput.isVisible, isFalse);
    });
  });
}

/// A shell that knows where it is standing, for the bar to watch.
class _ShellWithCwd extends FakeShell {
  _ShellWithCwd() : super((_) => ok(""));

  static const starting = "/tmp/project/workspace";

  final cwd = ValueNotifier<String?>(starting);

  @override
  ValueListenable<String?>? sessionCwd(String cwd, {String? home}) => this.cwd;
}

/// The same, masked: a guest the shell has said nothing of yet — what a
/// reopened chat is, until the shell's first report of its own.
class _MaskedShell extends FakeShell {
  _MaskedShell() : super((_) => ok(""));

  @override
  String? get guestRoot => "/root";
}
