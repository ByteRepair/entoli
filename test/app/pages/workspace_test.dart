import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/app/pages/context.dart";
import "package:agent_chat/app/settings/controller.dart";
import "package:agent_chat/domain/models.dart";

import "../../harness.dart";
import "page_driver.dart";

void main() {
  late TestApp app;

  void start() => app = TestApp.create();

  tearDown(() => app.dispose());

  group("the context", () {
    Message reply(String id, ContextUsage context, {String? author}) => Message(
      id: id,
      role: MessageRole.assistant,
      createdAt: DateTime.utc(2026),
      author: author,
      context: context,
    );

    test("a participant each, with what fills their window", () async {
      start();
      final chat = await app.seedChat();
      await app.writeChat(
        chat.copyWith(
          messages: [
            reply(
              "a1",
              const ContextUsage(
                system: 4000,
                tools: 6000,
                profile: 200,
                instructions: 3000,
                chat: 20000,
              ),
            ),
            reply(
              "a2",
              const ContextUsage(system: 100, tools: 100, profile: 0, chat: 50),
              author: "@reviewer",
            ),
          ],
        ),
      );
      final page = PageDriver(app, ContextAppPage(chat.state.id));
      await page.until(
        () =>
            page
                .find<CollectionController<String>>("participants")
                ?.items
                .length ==
            2,
      );
      final rows = page.at<CollectionController<String>>("participants").rows;
      expect(rows.map((r) => r.title), ["@athena", "@reviewer"]);
      final meter = rows.first.meters.single;
      expect(
        meter.segments.map((s) => "${s.label} · ${s.amount}"),
        contains("Instructions · 3.0k"),
      );
      expect(meter.mark?.label, "Auto-compact 80%");
      expect(meter.mark?.fraction, 0.8);
    });

    test("nothing measured says so", () async {
      start();
      final chat = await app.seedChat();
      final page = PageDriver(app, ContextAppPage(chat.state.id));
      final list = page.at<CollectionController<String>>("participants");
      expect(list.items, isEmpty);
      expect(list.emptyLabel, startsWith("Nothing measured yet."));
    });
  });
}
