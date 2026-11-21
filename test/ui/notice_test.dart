import "package:agent_chat/ui/widgets/notice.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  late BuildContext page;
  late int taps;

  Future<void> pumpPage(WidgetTester tester) async {
    taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            page = context;
            return Scaffold(
              body: SizedBox.expand(
                child: TextButton(
                  onPressed: () => taps++,
                  child: const Text("under"),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  testWidgets("the page under a notice still takes taps", (tester) async {
    await pumpPage(tester);
    notify(page, "Copied");
    await tester.pumpAndSettle();
    expect(find.text("Copied"), findsOneWidget);

    await tester.tapAt(const Offset(400, 500));
    expect(taps, 1);
    expect(find.text("Copied"), findsOneWidget);
  });

  testWidgets("a tap on the notice dismisses it", (tester) async {
    await pumpPage(tester);
    notify(page, "Copied");
    await tester.pumpAndSettle();

    await tester.tap(find.text("Copied"));
    await tester.pumpAndSettle();
    expect(find.text("Copied"), findsNothing);
    expect(taps, 0);
  });

  testWidgets("it leaves on its own", (tester) async {
    await pumpPage(tester);
    notify(page, "Copied");
    await tester.pumpAndSettle();

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text("Copied"), findsNothing);
  });

  testWidgets("a newer notice replaces the last", (tester) async {
    await pumpPage(tester);
    notify(page, "First");
    await tester.pumpAndSettle();
    say(page, "Second");
    await tester.pumpAndSettle();

    expect(find.text("First"), findsNothing);
    expect(find.text("Second"), findsOneWidget);
    expect(find.byTooltip("Copy"), findsOneWidget);
  });
}
