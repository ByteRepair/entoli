import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:entoli_core/model/agent_backend.dart";
import "package:agent_chat/app/chat_controller.dart";
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
  /// Pumps until [until], the last event's row: the spinner is up as soon as
  /// the turn starts, before the events reach the screen.
  Future<void> waitingAfter(
    WidgetTester tester,
    List<AgentEvent> events, {
    required Finder until,
  }) async {
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
    await pumpUntil(tester, until);
  }

  testWidgets("what the turn is doing is drawn beside the spinner", (
    tester,
  ) async {
    final status = find.text("Reading the prompt · 43%");
    await waitingAfter(tester, const [
      StatusEvent("Reading the prompt · 43%"),
    ], until: status);

    expect(status, findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });

  testWidgets("the latest replaces the last, since it is one row", (
    tester,
  ) async {
    final latest = find.text("Reading the prompt · 80%");
    await waitingAfter(tester, const [
      StatusEvent("Thinking"),
      StatusEvent("Reading the prompt · 80%"),
    ], until: latest);

    expect(latest, findsOneWidget);
    expect(find.text("Thinking"), findsNothing);
  });

  testWidgets("trouble takes the row over from the status", (tester) async {
    final trouble = find.textContaining("rate limited");
    await waitingAfter(tester, const [
      StatusEvent("Thinking"),
      RetryEvent(attempt: 2, message: "you have been rate limited"),
    ], until: trouble);

    // "Thinking" beside a retry would be the turn claiming to be fine while it
    // is not, and what the reader needs is the half that is news.
    expect(trouble, findsOneWidget);
    expect(find.text("Thinking"), findsNothing);
  });
}
