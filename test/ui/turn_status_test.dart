import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/agent_backend.dart";
import "package:agent_chat/ui/chat/chat_controller.dart";
import "package:agent_chat/ui/chat/chat_page.dart";
import "package:agent_chat/ui/chat/widgets/composer.dart";
import "package:agent_chat/ui/selection.dart";

import "../harness.dart";

/// The row the spinner is on. A spinner alone cannot be told apart from a hang,
/// and against a model running on the device that wait is minutes — so what is
/// worth pinning is that whatever the turn last said about itself is on screen
/// beside it, and that trouble still wins the row when there is any.
void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  /// A turn parked mid-flight after [events], the way `heldTurn` does it — but
  /// over a list, since what this file is about is one event replacing another.
  Future<void> waitingAfter(
    WidgetTester tester,
    List<AgentEvent> events,
  ) async {
    app.backend.scriptedEvents = events;
    app.backend.hold = Completer<void>();
    addTearDown(() => app.backend.hold?.complete());

    final chat = await io(tester, () => app.repo.createChat());
    final id = chat.state.id;
    app.container.read(selectedChatIdProvider.notifier).select(id);
    await app.pump(tester, const ChatPage(), settle: false);
    await pumpUntil(tester, find.byType(Composer));
    await io(
      tester,
      () => app.container.read(chatControllerProvider(id).notifier).send("go"),
    );
    await pumpUntil(tester, find.byType(CircularProgressIndicator));
  }

  testWidgets("what the turn is doing is drawn beside the spinner", (
    tester,
  ) async {
    await waitingAfter(tester, const [StatusEvent("Reading the prompt · 43%")]);

    expect(find.text("Reading the prompt · 43%"), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });

  testWidgets("the latest replaces the last, since it is one row", (
    tester,
  ) async {
    await waitingAfter(tester, const [
      StatusEvent("Thinking"),
      StatusEvent("Reading the prompt · 80%"),
    ]);

    expect(find.text("Reading the prompt · 80%"), findsOneWidget);
    expect(find.text("Thinking"), findsNothing);
  });

  testWidgets("a turn that has said nothing about itself is still a spinner", (
    tester,
  ) async {
    // Every provider but the local one goes from the request to the first token
    // with nothing in between, so the row has to read with nothing on it.
    await waitingAfter(tester, const [ResponseStart("reply-1")]);

    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });

  testWidgets("trouble takes the row over from the status", (tester) async {
    await waitingAfter(tester, const [
      StatusEvent("Thinking"),
      RetryEvent(attempt: 2, message: "you have been rate limited"),
    ]);

    // "Thinking" beside a retry would be the turn claiming to be fine while it
    // is not, and what the reader needs is the half that is news.
    expect(find.textContaining("rate limited"), findsOneWidget);
    expect(find.text("Thinking"), findsNothing);
  });
}
