import "dart:async";
import "dart:convert";

import "package:flutter/foundation.dart" show ValueListenable, ValueNotifier;
import "package:flutter/gestures.dart" show kPrimaryButton;
import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_browser.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/chat/widgets/browser_input.dart";
import "package:agent_chat/ui/chat/widgets/browser_strip.dart";

/// A one-pixel JPEG, which is all a frame has to be for `Image.memory`.
final _pixel = base64Decode(
    "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP////////////////////////////////////"
    "//////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBAB"
    "AAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=");

class _Tab implements BrowserTab {
  @override
  final ValueNotifier<BrowserPage?> page = ValueNotifier(null);

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
  Future<String> back() async {
    done.add("back");
    return "";
  }

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

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Browser implements AgentBrowser {
  final tabs = <String, _Tab>{};
  var quits = 0;

  @override
  Future<void> close() async => quits++;

  @override
  bool get available => true;

  @override
  bool get configured => true;

  @override
  BrowserTab tab(String chatId) => tabs.putIfAbsent(chatId, _Tab.new);

  @override
  ValueListenable<bool> get running => ValueNotifier(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Browser browser;

  Future<_Tab> pumpStrip(WidgetTester tester, {bool mirrored = false}) async {
    browser = _Browser();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        agentBrowserProvider.overrideWithValue(browser),
        isMirroredChatProvider("chat-1").overrideWithValue(mirrored),
      ],
      child: const MaterialApp(
        home: Scaffold(body: BrowserStrip(chatId: "chat-1")),
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
  Future<_Tab> openCard(WidgetTester tester) async {
    final tab = await pumpStrip(tester);
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
        buttons: kPrimaryButton);
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
}
