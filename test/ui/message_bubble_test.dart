import "package:flutter/gestures.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/chat/widgets/message_bubble.dart";

Message _message(MessageRole role, List<MessagePart> parts) =>
    Message(id: "m1", role: role, createdAt: DateTime(2026), parts: parts);

void main() {
  Future<void> pump(
    WidgetTester tester,
    Message message, {
    bool isWaiting = false,
    String? waitingNotice,
    ValueChanged<String>? onEdit,
    VoidCallback? onRegenerate,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageBubble(
          message: message,
          isWaiting: isWaiting,
          waitingNotice: waitingNotice,
          onEdit: onEdit,
          onRegenerate: onRegenerate,
        ),
      ),
    ));
  }

  /// Right-click, the way the menu is meant to be opened on desktop.
  Future<void> rightClick(WidgetTester tester, Finder target) async {
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.down(tester.getCenter(target));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets("an error part renders in the theme's error colour", (tester) async {
    await pump(tester, _message(MessageRole.assistant, [const ErrorPart(message: "usage limit reached")]));

    final rendered = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .firstWhere((t) => t.data!.contains("usage limit reached"));
    final context = tester.element(find.byType(MessageBubble));
    expect(rendered.style?.color, Theme.of(context).colorScheme.error);
  });

  testWidgets("an empty reply spins while the turn is running", (tester) async {
    await pump(tester, _message(MessageRole.assistant, const []), isWaiting: true);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets("the spinner gives way to the first text", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [const TextPart(text: "Hel")]),
      isWaiting: true,
    );

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text("Hel"), findsOneWidget);
  });

  testWidgets("a tool call with no text yet still spins", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [
        const ToolCallPart(toolCall: ToolCall(id: "1", name: "bash")),
      ]),
      isWaiting: true,
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets("a retry notice sits beside the spinner in red", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, const []),
      isWaiting: true,
      waitingNotice: "Attempt 1 failed: you have reached your session usage limit",
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final notice = tester.widget<Text>(find.textContaining("usage limit"));
    final context = tester.element(find.byType(MessageBubble));
    expect(notice.style?.color, Theme.of(context).colorScheme.error);
  });

  testWidgets("a finished empty reply does not spin", (tester) async {
    await pump(tester, _message(MessageRole.assistant, const []));

    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets("an errored reply shows the error, not a spinner", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [const ErrorPart(message: "usage limit reached")]),
      isWaiting: true,
    );

    expect(find.textContaining("usage limit reached"), findsOneWidget);
  });

  testWidgets("a failed reply offers Retry without hunting for the menu", (tester) async {
    var fired = 0;
    await pump(
      tester,
      _message(MessageRole.assistant, [const ErrorPart(message: "usage limit reached")]),
      onRegenerate: () => fired++,
    );

    await tester.tap(find.text("Retry"));
    await tester.pumpAndSettle();

    expect(fired, 1);
  });

  testWidgets("a reply still running offers no Retry", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [const ErrorPart(message: "rate limited")]),
      isWaiting: true,
      onRegenerate: () {},
    );

    expect(find.text("Retry"), findsNothing);
  });

  testWidgets("a healthy reply offers no Retry", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [const TextPart(text: "all good")]),
      onRegenerate: () {},
    );

    expect(find.text("Retry"), findsNothing);
  });

  testWidgets("a user message offers both Edit and Regenerate", (tester) async {
    await pump(
      tester,
      _message(MessageRole.user, [const TextPart(text: "hello")]),
      onEdit: (_) {},
      onRegenerate: () {},
    );

    await rightClick(tester, find.text("hello"));

    expect(find.text("Edit"), findsOneWidget);
    expect(find.text("Regenerate"), findsOneWidget);
  });

  testWidgets("an assistant message offers only Regenerate", (tester) async {
    await pump(
      tester,
      _message(MessageRole.assistant, [const TextPart(text: "hi there")]),
      onRegenerate: () {},
    );

    await rightClick(tester, find.text("hi there"));

    expect(find.text("Edit"), findsNothing);
    expect(find.text("Regenerate"), findsOneWidget);
  });

  testWidgets("Regenerate fires the callback", (tester) async {
    var fired = 0;
    await pump(
      tester,
      _message(MessageRole.user, [const TextPart(text: "hello")]),
      onRegenerate: () => fired++,
    );

    await rightClick(tester, find.text("hello"));
    await tester.tap(find.text("Regenerate"));
    await tester.pumpAndSettle();

    expect(fired, 1);
  });

  testWidgets("Edit opens the text prefilled and returns what was typed", (tester) async {
    String? edited;
    await pump(
      tester,
      _message(MessageRole.user, [const TextPart(text: "helo")]),
      onEdit: (text) => edited = text,
    );

    await rightClick(tester, find.text("helo"));
    await tester.tap(find.text("Edit"));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, "helo"), findsOneWidget);
    await tester.enterText(find.byType(TextField), "hello");
    await tester.tap(find.text("Send"));
    await tester.pumpAndSettle();

    expect(edited, "hello");
  });

  testWidgets("cancelling the edit resends nothing", (tester) async {
    String? edited;
    await pump(
      tester,
      _message(MessageRole.user, [const TextPart(text: "helo")]),
      onEdit: (text) => edited = text,
    );

    await rightClick(tester, find.text("helo"));
    await tester.tap(find.text("Edit"));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Cancel"));
    await tester.pumpAndSettle();

    expect(edited, isNull);
  });

  testWidgets("long-pressing the name label opens the menu on touch", (tester) async {
    await pump(
      tester,
      _message(MessageRole.user, [const TextPart(text: "hello")]),
      onRegenerate: () {},
    );

    await tester.longPress(find.text("You"));
    await tester.pumpAndSettle();

    expect(find.text("Regenerate"), findsOneWidget);
  });

  testWidgets("no menu appears when neither action is offered", (tester) async {
    await pump(tester, _message(MessageRole.user, [const TextPart(text: "hello")]));

    await rightClick(tester, find.text("hello"));

    expect(find.text("Regenerate"), findsNothing);
  });
}
