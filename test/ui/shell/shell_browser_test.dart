import "dart:async";
import "dart:typed_data";

import "package:entoli_glass/entoli_glass.dart";
import "package:flutter/foundation.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_browser.dart";
import "package:agent_chat/ui/shell/shell_answers.dart";
import "package:agent_chat/ui/shell/shell_browser.dart";
import "package:agent_chat/ui/shell/shell_outbox.dart";

import "fake_native_shell.dart";

/// A tab as far as the view needs one: its page, its hold, its frames, and
/// what the user's hands sent it.
class _Tab implements BrowserTab {
  @override
  final page = ValueNotifier<BrowserPage?>(
    const BrowserPage(url: "https://example.com/", title: "Example", opened: 1),
  );
  final _hold = ValueNotifier<BrowserHold?>(null);
  @override
  ValueListenable<BrowserHold?> get hold => _hold;
  final frameFeed = StreamController<BrowserFrame>.broadcast();
  final keys = <BrowserKey>[];
  final pointers = <BrowserPointer>[];

  @override
  Stream<BrowserFrame> frames() => frameFeed.stream;

  @override
  Future<void> key(BrowserKey event) async => keys.add(event);

  @override
  Future<void> pointer(BrowserPointer event) async => pointers.add(event);

  @override
  void hide(BrowserHold hold) => _hold.value = hold;

  @override
  void unhide() => _hold.value = null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late FakeNativeShell shell;
  late _Tab tab;
  late BrowserWindowSession session;
  var closed = 0;

  setUp(() {
    shell = FakeNativeShell.install();
    tab = _Tab();
    session = BrowserWindowSession(
      tab: tab,
      outbox: ShellOutbox(),
      answers: ShellAnswers(),
      onQuit: () async {},
      windowed: false,
      onClose: () => closed++,
    );
    addTearDown(session.dispose);
  });

  testWidgets("the view goes out with the page, and its frames as they come", (
    tester,
  ) async {
    await tester.pump();
    expect(shell.lastBrowser?.present, isTrue);
    expect(shell.lastBrowser?.title, "Example");
    expect(shell.lastBrowser?.url, "https://example.com/");

    tab.frameFeed.add(
      BrowserFrame(Uint8List.fromList([1, 2, 3]), width: 800, height: 600),
    );
    await tester.pump();
    final frame = shell.sent["browserFrame"]!.last as BrowserFrameSnapshot;
    expect(frame.width, 800);

    session.hide();
    await tester.pump();
    expect(shell.lastBrowser?.hidden, isTrue);
  });

  testWidgets("a platform key reaches the page as the page's key, and its "
      "release names the same key", (tester) async {
    // macOS's key code for A, typed as "a".
    session.key(true, 0, "a", 0);
    session.key(false, 0, "a", 0);
    await tester.pump();
    expect(tab.keys.map((k) => (k.down, k.key)), [(true, "a"), (false, "a")]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets("a click is the page's pointer, and closing lets the view go", (
    tester,
  ) async {
    session.pointer(BrowserPointerAction.down, 10, 20, "left", 1, 1, 0, 0, 0);
    await tester.pump();
    expect(tab.pointers.single.kind, BrowserPointerKind.down);
    expect((tab.pointers.single.x, tab.pointers.single.y), (10, 20));

    session.close();
    expect(closed, 1);
    session.dispose();
    await tester.pump();
    expect(shell.lastBrowser?.present, isFalse);
  });
}
