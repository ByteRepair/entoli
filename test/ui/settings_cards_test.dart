import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/app/pages/app_page.dart";
import "package:agent_chat/app/settings/controller.dart";
import "package:agent_chat/app/settings/spec.dart";

import "../harness.dart";

/// Two collections as cards; a tap says which was opened.
class _CardsPage extends AppPage {
  final tapped = <int>[];

  @override
  String get address => "cards";

  @override
  String title(SettingReader reader) => "Cards";

  @override
  List<PageSection> sections(SettingReader reader) => [
    PageSection("s", "", [
      CollectionController<String>(
        part("cards", "Cards", hint: UiHint.cards),
        items: const ["Google", "Microsoft"],
        removable: false,
        describe: (name) => CollectionItem(
          name,
          byline: "3 skills",
          subtitle: "About $name.",
          badge: "External",
          glyph: SettingGlyph.folder,
          editable: false,
          tap: "open",
        ),
        act: (index, _) async {
          tapped.add(index);
          return null;
        },
      ),
    ]),
  ];
}

void main() {
  testWidgets("a cards list draws each card, and a tap runs its own", (
    tester,
  ) async {
    final app = TestApp.create();
    addTearDown(app.dispose);
    final page = _CardsPage();
    await app.pumpPage(tester, page);

    expect(find.byType(Card), findsNWidgets(2));
    expect(find.text("About Microsoft."), findsOneWidget);
    expect(find.text("3 skills"), findsNWidgets(2));
    expect(find.text("External"), findsNWidgets(2));
    await tester.tap(find.text("Microsoft"));
    await settleIo(tester);
    expect(page.tapped, [1]);
  });
}
