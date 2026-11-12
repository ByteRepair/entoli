import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/shell/shell_outbox.dart";
import "package:agent_chat/ui/widgets/dialogs.dart";

import "fake_native_shell.dart";

void main() {
  testWidgets("a line said in passing is the shell's notice while it is "
      "bound, and a snack bar while it is not", (tester) async {
    final shell = FakeNativeShell.install();
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    nativeNotice = ShellOutbox().notice;
    addTearDown(() => nativeNotice = null);
    notify(context, "Message copied");
    say(context, "It did not work");
    await tester.pump();
    expect(shell.sent["notice"], ["Message copied", "It did not work"]);
    expect(find.byType(SnackBar), findsNothing);

    nativeNotice = null;
    notify(context, "Saved");
    await tester.pump();
    expect(find.text("Saved"), findsOneWidget);
  });
}
