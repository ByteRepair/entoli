import "dart:async";
import "dart:convert";

import "package:flutter/foundation.dart" show ValueListenable, ValueNotifier;
import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_browser.dart";
import "package:agent_chat/domain/models.dart";
import "package:agent_chat/domain/room/room_state.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/chat/widgets/browser_input.dart";
import "package:agent_chat/ui/chat/widgets/browser_strip.dart";
import "package:agent_chat/ui/chat/widgets/running_strip.dart";

import "../fakes.dart";
import "../harness.dart" show clipboard;

/// A one-pixel JPEG, which is all a frame has to be for `Image.memory`.
final _pixel = base64Decode(
    "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP////////////////////////////////////"
    "//////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBAB"
    "AAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=");

class _Tab implements BrowserTab {
  @override
  final ValueNotifier<BrowserPage?> page = ValueNotifier(null);

  @override
  bool get trustedInput => true;

  final frames$ = StreamController<BrowserFrame>.broadcast();
  var listened = 0;

  @override
  Stream<BrowserFrame> frames() {
    listened++;
    return frames$.stream;
  }

  /// What the user's hands did, in order.
  final done = <String>[];
  final pointers = <BrowserPointer>[];
  final keys = <BrowserKey>[];

  @override
  Future<void> historyBack() async => done.add("back");

  @override
  Future<void> show() async => done.add("window");

  @override
  Future<void> forward() async => done.add("forward");

  @override
  Future<void> reload() async => done.add("reload");

  @override
  Future<void> pointer(BrowserPointer event) async => pointers.add(event);

  @override
  Future<void> key(BrowserKey event) async => keys.add(event);

  @override
  Future<void> insertText(String text) async => done.add("insert $text");

  /// What the page has selected.
  String? selection;

  @override
  Future<String?> selectedText() async => selection;

  @override
  final ValueNotifier<BrowserHold?> hold = ValueNotifier(null);

  @override
  void hide(BrowserHold hold) => this.hold.value = hold;

  @override
  void unhide() => hold.value = null;

  @override
  final ValueNotifier<CredentialRequest?> credentialRequest = ValueNotifier(null);

  List<String>? submitted;

  @override
  final ValueNotifier<UploadRequest?> uploadRequest = ValueNotifier(null);

  @override
  void cancelUpload({String why = ""}) {
    done.add("upload cancelled");
    uploadRequest.value = null;
  }

  @override
  Future<void> submitCredentials(List<String> values) async {
    submitted = values;
    credentialRequest.value = null;
  }

  @override
  void declineCredentials() {
    done.add("declined");
    credentialRequest.value = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Browser implements AgentBrowser {
  final tabs = <String, _Tab>{};
  var quits = 0;

  @override
  Future<void> close({String why = ""}) async => quits++;

  @override
  bool get available => true;

  @override
  bool get configured => true;

  @override
  bool inApp = false;

  @override
  BrowserTab tab(String chatId) => tabs.putIfAbsent(chatId, _Tab.new);

  @override
  ValueListenable<bool> get running => ValueNotifier(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Browser browser;

  Future<_Tab> pumpStrip(WidgetTester tester,
      {bool mirrored = false, bool inApp = false}) async {
    browser = _Browser()..inApp = inApp;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        agentBrowserProvider.overrideWithValue(browser),
        isMirroredChatProvider("chat-1").overrideWithValue(mirrored),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Column(children: [
            const BrowserPrompts(chatId: "chat-1"),
            RunningStrip(
              view: ChatViewState(
                chat: Chat(
                  state: ChatState(
                    id: "chat-1",
                    title: "t",
                    createdAt: DateTime.utc(2026),
                    updatedAt: DateTime.utc(2026),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    ));
    return browser.tab("chat-1") as _Tab;
  }

  testWidgets("the chip shows only while the chat's tab is open", (tester) async {
    final tab = await pumpStrip(tester);
    expect(find.byType(ActionChip), findsNothing);

    tab.page.value = const BrowserPage(url: "https://example.com/a", opened: 1);
    await tester.pump();
    expect(find.text("Browser · example.com"), findsOneWidget);

    tab.page.value = null;
    await tester.pump();
    expect(find.byType(ActionChip), findsNothing);
  });

  testWidgets("a mirrored chat has no chip: its browser is elsewhere",
      (tester) async {
    final tab = await pumpStrip(tester, mirrored: true);
    tab.page.value = const BrowserPage(url: "https://example.com", opened: 1);
    await tester.pump();
    expect(find.byType(ActionChip), findsNothing);
  });

  testWidgets("the card shows the frames, and says when the tab closes",
      (tester) async {
    final tab = await pumpStrip(tester);
    tab.page.value = const BrowserPage(
        url: "https://example.com", title: "Example", opened: 1);
    await tester.pump();
    await tester.tap(find.byType(ActionChip));
    await tester.pump();
    expect(find.text("Example"), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tab.listened, 1);

    tab.frames$.add(BrowserFrame(Uint8List.fromList(_pixel), width: 1280, height: 800));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);

    tab.page.value = null;
    await tester.pump();
    expect(find.text("Closed"), findsOneWidget);
  });

  testWidgets("a tab reopened under an open card is listened to again",
      (tester) async {
    final tab = await pumpStrip(tester);
    tab.page.value = const BrowserPage(url: "https://example.com", opened: 1);
    await tester.pump();
    await tester.tap(find.byType(ActionChip));
    await tester.pump();
    tab.page.value = tab.page.value!.copyWith(url: "https://example.com/next");
    await tester.pump();
    expect(tab.listened, 1);

    tab.page.value = const BrowserPage(url: "https://example.com", opened: 2);
    await tester.pump();
    expect(tab.listened, 2);
  });

  /// The card open over a tab drawing a 1280×800 page.
  Future<_Tab> openCard(WidgetTester tester, {bool inApp = false}) async {
    final tab = await pumpStrip(tester, inApp: inApp);
    tab.page.value = const BrowserPage(url: "https://example.com", opened: 1);
    await tester.pump();
    await tester.tap(find.byType(ActionChip));
    await tester.pump();
    tab.frames$.add(BrowserFrame(Uint8List.fromList(_pixel), width: 1280, height: 800));
    await tester.pump();
    return tab;
  }

  testWidgets("back, forward, reload and quit reach the browser", (tester) async {
    final tab = await openCard(tester);
    await tester.tap(find.byTooltip("Back"));
    await tester.tap(find.byTooltip("Forward"));
    await tester.tap(find.byTooltip("Reload"));
    await tester.pump();
    expect(tab.done, ["back", "forward", "reload"]);

    await tester.tap(find.byTooltip("Quit the browser"));
    await tester.pump();
    expect(browser.quits, 1);
  });

  testWidgets("a click lands at the page's point, not the card's", (tester) async {
    final tab = await openCard(tester);
    final image = find.byType(Image);
    final box = tester.getRect(image);
    // A quarter of the way in on each axis is a quarter of the page.
    await tester.tapAt(box.topLeft + Offset(box.width / 4, box.height / 4),
        buttons: kPrimaryButton, kind: PointerDeviceKind.mouse);
    await tester.pump();
    final down =
        tab.pointers.firstWhere((p) => p.kind == BrowserPointerKind.down);
    expect(down.x, closeTo(320, 1));
    expect(down.y, closeTo(200, 1));
    expect(down.button, "left");
    expect(down.clickCount, 1);
    final up = tab.pointers.lastWhere((p) => p.kind == BrowserPointerKind.up);
    expect(up.button, "left");
  });

  test("a shortcut is a command, not text", () {
    const press = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: LogicalKeyboardKey.keyA,
      character: "a",
      timeStamp: Duration.zero,
    );
    final typed = browserKeyDown(press, modifiers: 0, shortcut: false)!;
    expect(typed.text, "a");
    expect(typed.commands, isEmpty);

    final control = browserModifiers(
        alt: false, control: true, meta: false, shift: false);
    final selectAll =
        browserKeyDown(press, modifiers: control, shortcut: true)!;
    expect(selectAll.text, isNull);
    expect(selectAll.commands, ["selectAll"]);
    expect(selectAll.modifiers, 2);
  });

  testWidgets("a right click opens a menu, and Copy fills the user's clipboard",
      (tester) async {
    final copied = clipboard(tester);
    final tab = await openCard(tester);
    tab.selection = "chosen words";
    await tester.tapAt(tester.getCenter(find.byType(Image)),
        buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    // The press is the card's, not the page's.
    expect(tab.pointers.where((p) => p.kind != BrowserPointerKind.move), isEmpty);
    expect(find.text("Paste"), findsOneWidget);
    await tester.tap(find.text("Copy"));
    await tester.pumpAndSettle();
    expect(copied, ["chosen words"]);
    final downs = tab.keys.where((k) => k.down).toList();
    expect(downs.single.commands, ["copy"]);
  });

  testWidgets("a wheel scrolls the page by the page's pixels", (tester) async {
    final tab = await openCard(tester);
    final box = tester.getRect(find.byType(Image));
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(box.center));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 50)));
    await tester.pump();
    final wheel =
        tab.pointers.singleWhere((p) => p.kind == BrowserPointerKind.wheel);
    expect(wheel.deltaY, closeTo(50 * 1280 / box.width, 1));
  });

  testWidgets("a finger dragged up scrolls the page down, and clicks nothing",
      (tester) async {
    final tab = await openCard(tester);
    final box = tester.getRect(find.byType(Image));
    await tester.dragFrom(box.center, const Offset(0, -100),
        kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(tab.pointers.where((p) => p.kind == BrowserPointerKind.down), isEmpty);
    final scrolled = tab.pointers
        .where((p) => p.kind == BrowserPointerKind.wheel)
        .fold<double>(0, (sum, p) => sum + p.deltaY);
    expect(scrolled, greaterThan(0));
  });

  testWidgets("a tap of a finger is a click", (tester) async {
    final tab = await openCard(tester);
    await tester.tapAt(tester.getCenter(find.byType(Image)),
        kind: PointerDeviceKind.touch);
    await tester.pump();
    expect([for (final p in tab.pointers) p.kind],
        [BrowserPointerKind.down, BrowserPointerKind.up]);
    expect(tab.pointers.first.button, "left");
  });

  testWidgets("two fingers on a trackpad scroll the page", (tester) async {
    final tab = await openCard(tester);
    final center = tester.getCenter(find.byType(Image));
    final pad = TestPointer(2, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pad.panZoomStart(center));
    await tester.sendEventToBinding(
        pad.panZoomUpdate(center, pan: const Offset(0, -40)));
    await tester.sendEventToBinding(pad.panZoomEnd());
    await tester.pump();
    final wheel =
        tab.pointers.singleWhere((p) => p.kind == BrowserPointerKind.wheel);
    expect(wheel.deltaY, greaterThan(0));
  });

  testWidgets("keys typed into the viewport go to the page", (tester) async {
    final tab = await openCard(tester);
    await tester.tap(find.byType(Image));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    // Escape is the page's too, rather than closing the card.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    final downs = tab.keys.where((k) => k.down).toList();
    expect([for (final k in downs) k.key], ["a", "Enter", "Escape"]);
    expect(downs.first.text, "a");
    expect(downs.first.code, "KeyA");
    expect(tab.keys.where((k) => !k.down), hasLength(3));
    expect(find.byType(BrowserCard), findsOneWidget);
  });

  test("a chat with its browser open is busy, turn or no turn", () {
    final backend = FakeBackend();
    final tabs = ValueNotifier<Set<String>>(const {});
    final container = ProviderContainer(overrides: [
      agentBackendProvider.overrideWithValue(backend),
      agentBrowserProvider.overrideWithValue(_TabsBrowser(tabs)),
    ]);
    addTearDown(container.dispose);
    final busy = container.read(busyChatsProvider);
    backend.runningTurns.value = {"a"};
    tabs.value = {"b"};
    expect(busy.value, {"a", "b"});
    backend.runningTurns.value = const {};
    expect(busy.value, {"b"});
    tabs.value = const {};
    expect(busy.value, isEmpty);
  });

  group("private input", () {
    testWidgets("the sign-in panel hands what is typed to the tab alone",
        (tester) async {
      final tab = await pumpStrip(tester);
      tab.credentialRequest.value = const CredentialRequest(
        reason: "Sign in to Example",
        fields: [
          CredentialField(ref: 3, label: "Email"),
          CredentialField(ref: 4, label: "Password", secret: true),
        ],
      );
      await tester.pump();
      expect(find.text("Sign in to Example"), findsOneWidget);
      final password = find.widgetWithText(TextField, "Password");
      expect(tester.widget<TextField>(password).obscureText, isTrue);

      await tester.enterText(find.widgetWithText(TextField, "Email"), "me@example.com");
      await tester.enterText(password, "hunter2");
      await tester.tap(find.text("Sign in"));
      await tester.pump();
      expect(tab.submitted, ["me@example.com", "hunter2"]);
      expect(find.text("Sign in to Example"), findsNothing);
    });

    testWidgets("an upload waits on the user's file, and can be cancelled",
        (tester) async {
      final tab = await pumpStrip(tester);
      tab.uploadRequest.value = const UploadRequest(
          target: "[4] button", url: "https://drive.google.com/drive");
      await tester.pump();
      expect(find.text("The agent wants to upload a file to drive.google.com"),
          findsOneWidget);
      // Nothing to send until a file is chosen.
      final upload = find.widgetWithText(FilledButton, "Upload");
      expect(tester.widget<FilledButton>(upload).onPressed, isNull);
      await tester.tap(find.text("Cancel"));
      await tester.pump();
      expect(tab.done, ["upload cancelled"]);
      expect(find.textContaining("wants to upload"), findsNothing);
    });

    testWidgets("declining tells the tab", (tester) async {
      final tab = await pumpStrip(tester);
      tab.credentialRequest.value = const CredentialRequest(
          reason: "Sign in", fields: [CredentialField(ref: 1, label: "Email")]);
      await tester.pump();
      await tester.tap(find.text("Decline"));
      await tester.pump();
      expect(tab.done, ["declined"]);
    });

    testWidgets("the agent's reason is a button that opens the browser",
        (tester) async {
      final tab = await pumpStrip(tester);
      tab.page.value = const BrowserPage(url: "https://accounts.google.com", opened: 1);
      tab.hide(const BrowserHold(reason: "Please sign in to Google to proceed"));
      await tester.pump();
      expect(find.textContaining("hidden from the agent"), findsOneWidget);
      await tester.tap(find.text("Please sign in to Google to proceed"));
      await tester.pump();
      expect(find.byType(BrowserCard), findsOneWidget);

      await tester.tap(find.text("Give back to agent"));
      await tester.pump();
      expect(tab.hold.value, isNull);
    });

    testWidgets("the agent's button goes when the browser is given back",
        (tester) async {
      final tab = await pumpStrip(tester);
      tab.page.value = const BrowserPage(url: "https://accounts.google.com", opened: 1);
      tab.hide(const BrowserHold(reason: "Sign in to Google"));
      await tester.pump();
      expect(find.text("Sign in to Google"), findsOneWidget);
      tab.unhide();
      await tester.pump();
      expect(find.text("Sign in to Google"), findsNothing);
      expect(find.textContaining("hidden from the agent"), findsNothing);
    });

    testWidgets("and when a quit clears it with the tab gone", (tester) async {
      final tab = await pumpStrip(tester);
      tab.page.value = const BrowserPage(url: "https://accounts.google.com", opened: 1);
      tab.hide(const BrowserHold(reason: "Sign in to Google"));
      await tester.pump();
      // What the quit does to the tab: no page, no hold.
      tab.page.value = null;
      tab.hold.value = null;
      await tester.pump();
      expect(find.text("Sign in to Google"), findsNothing);
      expect(find.byType(ActionChip), findsNothing);
    });

    testWidgets("the card opens the browser in a window, as the user",
        (tester) async {
      final tab = await openCard(tester);
      await tester.tap(find.byTooltip("Open in a window"));
      await tester.pump();
      expect(tab.done, ["window"]);
    });

    testWidgets("an in-app browser's card has no window to open",
        (tester) async {
      await openCard(tester, inApp: true);
      expect(find.byTooltip("Open in a window"), findsNothing);
    });

    testWidgets("the card hides the browser from the agent, and gives it back",
        (tester) async {
      final tab = await openCard(tester);
      await tester.tap(find.byTooltip("Hide from agent"));
      await tester.pump();
      expect(tab.hold.value, isNotNull);
      expect(tab.hold.value!.byAgent, isFalse);
      await tester.tap(find.byTooltip("Give back to agent"));
      await tester.pump();
      expect(tab.hold.value, isNull);
    });
  });
}

/// A browser that is only its set of open tabs.
class _TabsBrowser implements AgentBrowser {
  _TabsBrowser(this.openTabs);

  @override
  final ValueNotifier<Set<String>> openTabs;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
