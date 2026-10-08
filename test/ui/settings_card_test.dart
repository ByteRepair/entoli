import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/sidebar/project_settings_page.dart";
import "package:agent_chat/ui/widgets/settings_card.dart";
import "package:agent_chat/ui/workspace/workspace_page.dart";

import "../harness.dart";

void main() {
  late TestApp app;
  setUp(() => app = TestApp.create());
  tearDown(() => app.dispose());

  group("SettingsCard", () {
    testWidgets("the copy card copies its value, the whole card the button",
        (tester) async {
      final copied = clipboard(tester);
      await app.pump(
        tester,
        Scaffold(
          body: ListView(children: [
            SettingsCard.copy(
              icon: Icons.badge_outlined,
              title: "Project name",
              value: "research",
              said: "Copied project name",
            ),
          ]),
        ),
      );

      await tester.tap(find.text("research"));
      await settleIo(tester);

      expect(copied, ["research"]);
      expect(find.text("Copied project name"), findsOneWidget);
    });

    testWidgets("a tappable card ends in the arrow, and its tap runs",
        (tester) async {
      var pushed = false;
      await app.pump(
        tester,
        Scaffold(
          body: ListView(children: [
            SettingsCard(
              icon: Icons.key_outlined,
              title: "Environment",
              subtitle: "Default (inherited)",
              onTap: () => pushed = true,
            ),
          ]),
        ),
      );

      expect(find.byIcon(Icons.arrow_right), findsOneWidget);
      await tester.tap(find.text("Environment"));
      await tester.pump();
      expect(pushed, isTrue);
    });

    testWidgets("a card with no tap has no arrow and answers no gesture",
        (tester) async {
      await app.pump(
        tester,
        Scaffold(
          body: ListView(children: [
            const SettingsCard(
              icon: Icons.forum_outlined,
              title: "Chats",
              subtitle: "1",
            ),
          ]),
        ),
      );

      expect(find.byIcon(Icons.arrow_right), findsNothing);
      expect(
        find.byWidgetPredicate((w) =>
            w is InkWell && w.onTap != null || w is InkResponse && w.onTap != null),
        findsNothing,
      );
    });

    testWidgets("a trailing element takes the arrow's place", (tester) async {
      await app.pump(
        tester,
        Scaffold(
          body: ListView(children: [
            SettingsCard(
              icon: Icons.description_outlined,
              title: "Description",
              subtitle: "Empty",
              trailing: IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: "Reset",
                onPressed: () {},
              ),
            ),
          ]),
        ),
      );

      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.byIcon(Icons.arrow_right), findsNothing);
    });
  });

  group("SettingsCardRow", () {
    testWidgets("a phone-width row lays two equal cards out", (tester) async {
      await app.pump(
        tester,
        Scaffold(
          body: ListView(children: [
            Center(
              child: SizedBox(
                width: 400,
                child: SettingsCardRow(children: [
                  _card("One"),
                  _card("Two"),
                  _card("Three"),
                ]),
              ),
            ),
          ]),
        ),
      );

      final sizes = tester
          .widgetList<SizedBox>(find.byType(SizedBox))
          .where((s) => (s.width ?? 0) > 100 && s.width != 400.0)
          .toList();
      expect(sizes, hasLength(3));
      // Two per line at this width — the third wraps beneath, at the same
      // fixed width, every card the same size.
      expect(sizes[0].width, sizes[1].width);
      expect(sizes[2].width, sizes[0].width);
      expect(sizes[0].width, (400 - 8) / 2);
    });

    testWidgets("a wide row's cards are capped, not stretched", (tester) async {
      useWindow(tester, const Size(1200, 800));
      await app.pump(
        tester,
        Scaffold(
          body: ListView(children: [
            SettingsCardRow(children: [_card("One"), _card("Two")]),
          ]),
        ),
      );

      final sizes = tester
          .widgetList<SizedBox>(find.byType(SizedBox))
          .where((s) => (s.width ?? 0) > 100)
          .toSet()
          .map((s) => s.width)
          .toSet();
      expect(sizes, {240.0});
    });
  });

  group("the project settings page", () {
    testWidgets("the name card copies, without its own copy button",
        (tester) async {
      final copied = clipboard(tester);
      await io(tester, () => app.repo.createProject("research"));
      await app.pump(tester, const ProjectSettingsPage(project: "research"));

      await tester.tap(find.text("research"));
      await settleIo(tester);

      expect(copied, ["research"]);
      expect(find.text("Copied project name"), findsOneWidget);
    });

    testWidgets("the chats card states its count and takes no tap",
        (tester) async {
      await io(tester, () => app.repo.createProject("research"));
      await io(tester, () => app.seedChat(project: "research"));
      await app.pump(tester, const ProjectSettingsPage(project: "research"));

      expect(find.widgetWithText(SettingsCard, "Chats"), findsOneWidget);
      await tester.tap(find.text("Chats"));
      await settleIo(tester);

      expect(find.byType(WorkspacePage), findsNothing);
    });
  });
}

SettingsCard _card(String title) => SettingsCard(
      icon: Icons.folder_outlined,
      title: title,
      subtitle: "Browse files",
    );