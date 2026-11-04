import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/providers.dart";
import "package:agent_chat/ui/incoming_links.dart";
import "package:agent_chat/ui/selection.dart";

import "package:path/path.dart" as p;

import "../harness.dart";

const _box =
    '{"version":1,"id":"box","name":"Box","body":{"path":"M20 20 H80 V80 H20 Z"},'
    '"eyes":{"x":50,"y":46,"spacing":15,"scale":1}}';

void main() {
  late TestApp app;

  tearDown(() => app.dispose());

  // The controller is made inside the test, so its events run on the test's
  // fake clock rather than the real one.
  Future<void> open(WidgetTester tester, String link) async {
    final links = StreamController<Uri>();
    app = TestApp.create(links: links.stream);
    await app.pump(
      tester,
      const IncomingLinks(child: Scaffold(body: Text("chat"))),
    );
    links.add(Uri.parse(link));
    // A live avatar never settles, so the route's transition is pumped out.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  testWidgets("an avatar link shows the bot and installs it", (tester) async {
    await open(
      tester,
      "entoli://install/avatar?def=${Uri.encodeComponent(_box)}",
    );

    expect(find.text("Install Bot Avatar"), findsOneWidget);
    expect(find.text("Box"), findsOneWidget);
    await tester.tap(find.text("Install"));
    await settleIo(tester);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }

    expect(find.text("chat"), findsOneWidget);
    final installed = await app.container.read(
      importedBotAvatarsProvider.future,
    );
    expect(installed.map((d) => d.id), ["box"]);
  });

  testWidgets("a shared agent link shows the prompt and installs it", (
    tester,
  ) async {
    const prompt =
        "---\nname: diary\ndescription: Keeps a diary.\n---\nWrite it down.";
    final def = base64Url.encode(gzip.encode(utf8.encode(prompt)));
    await open(tester, "entoli://install/agent?def=$def");

    expect(find.text("diary"), findsOneWidget);
    expect(find.text("Write it down."), findsOneWidget);
    await tester.tap(find.text("Install agent"));
    await settleIo(tester, least: 20, tries: 80);

    final agentsDir = app.config.promptsDir(CompletionKind.agent);
    expect(File(p.join(agentsDir, "diary.md")).readAsStringSync(), prompt);
  });

  testWidgets("a new-chat link leaves its prompt for the new chat", (
    tester,
  ) async {
    await open(tester, "entoli://new?prompt=hello%20there");

    expect(app.container.read(newChatPromptProvider), "hello there");
  });
}
