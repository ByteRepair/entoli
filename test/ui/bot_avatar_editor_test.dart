import "dart:convert";
import "dart:io";

import "package:agent_chat/domain/bot_avatar/pose.dart";
import "package:agent_chat/domain/bot_avatar/spec.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/bot_avatar/bot_avatar_editor.dart";
import "package:agent_chat/ui/bot_avatar/bot_avatar_view.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "../harness.dart";

/// A definition a model might have written, wrapped in the prose round it.
const _reply = """
Here is your avatar:
```json
{
  "version": 1,
  "id": "box",
  "name": "Box",
  "body": { "path": "M20 20 H80 V80 H20 Z" },
  "eyes": { "x": 50, "y": 46, "spacing": 15, "scale": 1 }
}
```
""";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  Future<void> open(WidgetTester tester, {BotAvatarSpec? initial}) async {
    // The presets are an asset read, which wants a real clock to land.
    await tester.runAsync(
      () => app.container.read(botAvatarPresetsProvider.future),
    );
    await app.pump(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              final spec = await Navigator.of(context).push<BotAvatarSpec>(
                MaterialPageRoute(
                  builder: (_) => BotAvatarEditorPage(initial: initial),
                ),
              );
              if (spec != null) picked = spec;
            },
            child: const Text("open"),
          ),
        ),
      ),
    );
    await tester.tap(find.text("open"));
    await frames(tester, 30);
  }

  Rect stage(WidgetTester tester) => tester.getRect(
    find.byWidgetPredicate((w) => w is BotAvatarView && w.animate),
  );

  testWidgets("a tall screen has the preview over the controls, a wide one "
      "beside them", (tester) async {
    useWindow(tester, const Size(420, 860));
    await open(tester);
    final tabs = tester.getRect(find.byType(TabBar));
    expect(stage(tester).bottom, lessThanOrEqualTo(tabs.top));

    useWindow(tester, const Size(1100, 640));
    await frames(tester);
    final wide = tester.getRect(find.byType(TabBar));
    expect(stage(tester).right, lessThanOrEqualTo(wide.left));
  });

  testWidgets("every preset is offered, and Use hands back the one chosen in "
      "the colour picked", (tester) async {
    useWindow(tester, _tall);
    await open(tester);
    expect(
      find.byWidgetPredicate((w) => w is BotAvatarView && !w.animate),
      findsNWidgets(22),
    );

    await tester.tap(find.bySemanticsLabel("Ghost"));
    await frames(tester);
    await tester.tap(find.byTooltip("Teal"));
    await frames(tester);
    // The moods are the preview's; they change nothing that is saved.
    await tester.tap(find.text("Happy"));
    await frames(tester);
    expect(
      tester
          .widget<BotAvatarView>(
            find.byWidgetPredicate((w) => w is BotAvatarView && w.animate),
          )
          .mood,
      BotMood.happy,
    );

    await tester.tap(find.text("Use"));
    await frames(tester);
    expect(picked?.definition.id, "ghost");
    expect(picked?.colour, BotPalette.teal.rgb);
  });

  testWidgets("an import joins the Bots tab and a long press deletes it", (
    tester,
  ) async {
    useWindow(tester, _tall);
    await open(tester);
    await tester.tap(find.text("Import"));
    await frames(tester);
    await tester.enterText(find.byType(TextField), _reply);
    await tester.ensureVisible(_importButton);
    await tester.pump();
    await tester.tap(_importButton);
    await frames(tester, 30);

    // Back on Bots with it chosen, and written where the library lives.
    final file = File(app.config.botAvatarsFile);
    expect((jsonDecode(file.readAsStringSync()) as List).single["id"], "box");
    final box = find.bySemanticsLabel("Box");
    expect(box, findsWidgets);

    await tester.longPress(box.last);
    await frames(tester);
    await tester.tap(find.text("Delete Box"));
    await frames(tester, 30);
    expect(jsonDecode(file.readAsStringSync()), isEmpty);
    expect(find.bySemanticsLabel("Box"), findsNothing);
  });

  testWidgets("a paste that is not a definition says why", (tester) async {
    useWindow(tester, _tall);
    await open(tester);
    await tester.tap(find.text("Import"));
    await frames(tester);
    await tester.enterText(find.byType(TextField), '{"version": 2}');
    await tester.ensureVisible(_importButton);
    await tester.pump();
    await tester.tap(_importButton);
    await frames(tester);
    expect(find.text("version must be 1"), findsOneWidget);
    expect(File(app.config.botAvatarsFile).existsSync(), isFalse);
  });
}

BotAvatarSpec? picked;

/// Tall enough for the whole grid and the whole Import tab: both are lazy
/// lists, and what is off screen is not built to be found.
const _tall = Size(480, 1500);

final _importButton = find.ancestor(
  of: find.text("Import"),
  matching: find.byWidgetPredicate((w) => w is FilledButton),
);
