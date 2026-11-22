import "package:agent_chat/app/settings/controller.dart";
import "package:agent_chat/app/settings/spec.dart";
import "package:agent_chat/ui/settings/schema_view.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "../harness.dart";

SettingSpec _spec(String id, {UiHint hint = UiHint.row}) => SettingSpec(
  id: id,
  path: (page: null, section: ""),
  weight: 0,
  title: id,
  hint: hint,
  build: (_) => throw UnimplementedError(),
);

Future<void> _pump(WidgetTester tester, SettingController c) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ListView(children: [SettingRow(c)])),
      ),
    );

void main() {
  testWidgets("a row with nothing to do has no menu, however narrow", (
    tester,
  ) async {
    useWindow(tester, const Size(400, 800));
    await _pump(
      tester,
      CollectionController<String>(
        _spec("providers"),
        items: const ["OpenRouter"],
        removable: false,
        describe: (name) => CollectionItem(name, id: name),
      ),
    );

    expect(find.text("OpenRouter"), findsOneWidget);
    expect(find.byType(PopupMenuButton<ItemAction>), findsNothing);
  });

  testWidgets("a field with a send button says it once, when sent", (
    tester,
  ) async {
    final said = <String>[];
    await _pump(
      tester,
      TextController(
        _spec("code", hint: UiHint.input),
        value: "",
        submitLabel: "Send",
        onSet: (code) async {
          said.add(code);
          return null;
        },
      ),
    );

    await tester.enterText(find.byType(TextField), "AB12");
    await tester.pump();
    expect(said, isEmpty);

    await tester.tap(find.byTooltip("Send"));
    await tester.pump();
    expect(said, ["AB12"]);
    expect(find.text("AB12"), findsNothing);
  });

  testWidgets("an action that throws says it did not work", (tester) async {
    await _pump(
      tester,
      ActionController(
        _spec("save", hint: UiHint.button),
        run: () async => throw const FileSystemExceptionLike("disk full"),
      ),
    );

    await tester.tap(find.text("save"));
    await tester.pump();

    expect(find.textContaining("That did not work: disk full"), findsOneWidget);
    // The notice leaves on a timer of its own.
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });
}

class FileSystemExceptionLike implements Exception {
  const FileSystemExceptionLike(this.message);

  final String message;

  @override
  String toString() => message;
}
