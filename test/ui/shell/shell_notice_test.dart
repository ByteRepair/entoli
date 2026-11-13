import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/shell/shell_outbox.dart";
import "package:agent_chat/ui/widgets/dialogs.dart";
import "package:agent_chat/ui/widgets/native_surfaces.dart";

import "fake_native_shell.dart";

/// The shell's notice and nothing else.
class _Notices implements NativeSurfaces {
  final _outbox = ShellOutbox();

  @override
  void notice(String message) => _outbox.notice(message);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets("a line said in passing is the shell's notice while it is "
      "bound, and a snack bar while it is not", (tester) async {
    final shell = FakeNativeShell.install();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    late BuildContext context;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) {
                context = c;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );

    final surfaces = _Notices();
    container.read(nativeSurfacesProvider).bind(surfaces);
    notify(context, "Message copied");
    say(context, "It did not work");
    await tester.pump();
    expect(shell.sent["notice"], ["Message copied", "It did not work"]);
    expect(find.byType(SnackBar), findsNothing);

    container.read(nativeSurfacesProvider).unbind(surfaces);
    notify(context, "Saved");
    await tester.pump();
    expect(find.text("Saved"), findsOneWidget);
  });
}
