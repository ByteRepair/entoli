import "dart:io";

import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "package:agent_chat/domain/models.dart";
import "package:agent_chat/ui/widgets/attachment_chip.dart";

import "../fakes.dart" show onePixelPng;
import "../harness.dart";

void main() {
  late TestApp app;

  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  const part = FilePart(
    resource: "96fa4649-c736-47b5-ac9f-d2f09cf2a4a4-cat.png",
    filename: "cat.png",
    mimeType: "image/png",
  );

  Future<void> pumpChip(WidgetTester tester, String chatId) async {
    await app.pump(
      tester,
      Scaffold(body: AttachmentChip.sent(part, chatId: chatId)),
      settle: false,
    );
    await settleIo(tester);
  }

  testWidgets("an image draws itself", (tester) async {
    final chat = await io(tester, () => app.seedChat());
    final file = File(
      p.join(app.config.resourcesDir(chat.state.id), part.resource),
    );
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(onePixelPng);

    await pumpChip(tester, chat.state.id);

    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.block), findsNothing);
  });

  testWidgets("an image that is not here is its box with a stop sign", (
    tester,
  ) async {
    final chat = await io(tester, () => app.seedChat());

    await pumpChip(tester, chat.state.id);

    expect(find.byIcon(Icons.block), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byTooltip("cat.png is not here"), findsOneWidget);
  });
}
