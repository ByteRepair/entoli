import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/app_chrome.dart" show appChromeProvider;
import "package:agent_chat/ui/shell/shell_app_chrome.dart";
import "package:agent_chat/ui/chat/chat_chrome.dart" show chatChromeProvider;
import "package:agent_chat/ui/shell/shell_chat_chrome.dart";
import "package:agent_chat/ui/shell/shell_page_bar.dart" show drawShellPageBar;
import "package:agent_chat/ui/widgets/page_bar.dart" show pageBarDrawProvider;
import "package:agent_chat/domain/reaction.dart";
import "package:agent_chat/ui/chat/widgets/reaction_button.dart";
import "package:agent_chat/app/frontend.dart";

import "fake_native_shell.dart";

/// The reaction strip under the native shell: asked of the Swift, where the
/// button is, and answered with what was picked.
void main() {
  late FakeNativeShell shell;

  /// The Swift, answering every strip with [answer].
  void swiftAnswers(int? answer) =>
      (shell = FakeNativeShell.install()).stripAnswer = answer;

  Future<List<Reaction>> pump(
    WidgetTester tester, {
    List<String> chosen = const [],
  }) async {
    final reacted = <Reaction>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pageBarDrawProvider.overrideWithValue(drawShellPageBar),
          chatChromeProvider.overrideWithValue(const ShellChatChrome()),
          appChromeProvider.overrideWithValue(const ShellAppChrome()),
          frontendProvider.overrideWithValue(
            const FrontendChoice(current: Frontend.swiftUI, native: true),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: ReactionButton(onReact: reacted.add, chosen: chosen),
            ),
          ),
        ),
      ),
    );
    return reacted;
  }

  testWidgets("the shell is asked at the button, and its pick reacts", (
    tester,
  ) async {
    swiftAnswers(2);
    final reacted = await pump(tester, chosen: [Reaction.thumbsUp.emoji]);
    await tester.tap(find.byType(ReactionButton));
    await tester.pumpAndSettle();

    final strip = shell.strips.single;
    final button = tester.getRect(find.byType(ReactionButton));
    expect(strip.x, button.left);
    expect(strip.y, button.top);
    expect(strip.options.map((c) => c.glyph), [
      for (final r in Reaction.values) r.emoji,
    ]);
    expect(strip.options.first.chosen, isTrue);
    expect(reacted, [Reaction.values[2]]);
    expect(find.byType(IconButton), findsOneWidget, reason: "no Flutter strip");
  });

  testWidgets("a strip dismissed reacts with nothing", (tester) async {
    swiftAnswers(null);
    final reacted = await pump(tester);
    await tester.tap(find.byType(ReactionButton));
    await tester.pumpAndSettle();
    expect(reacted, isEmpty);
  });
}
