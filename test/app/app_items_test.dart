import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/app/app_items.dart";
import "package:agent_chat/domain/availability.dart";

void main() {
  const facts = (
    front: true,
    chatOpen: false,
    pinned: false,
    running: false,
    sidebarShown: true,
    hasWorkspace: true,
    hasMemories: true,
    hasSettings: true,
  );

  test("every action and destination is listed once", () {
    expect(appItems.toSet(), {...AppAction.values, ...Destination.values});
    expect(
      appItems.length,
      AppAction.values.length + Destination.values.length,
    );
  });

  // Where there is a menu bar it holds the keys, and the key handler stands
  // down: a keyed item the menus left out would answer no key at all.
  test("every item with keys is in the menus", () {
    expect([
      for (final item in appItems)
        if (item.key != null && !inAppMenus(item)) item.id,
    ], isEmpty);
  });

  test("a chat's items wait for a chat, and Stop for a turn", () {
    expect(availabilityOf(AppAction.pinChat, facts), isA<Unavailable>());
    expect(availabilityOf(AppAction.stopTurn, facts), isA<Unavailable>());
    expect(availabilityOf(AppAction.newChat, facts), isA<Available>());
  });

  test("only an item that is anywhere runs over a page", () {
    final covered = (
      front: false,
      chatOpen: true,
      pinned: false,
      running: true,
      sidebarShown: true,
      hasWorkspace: true,
      hasMemories: true,
      hasSettings: true,
    );
    expect(availabilityOf(Destination.settings, covered), isA<Available>());
    expect(availabilityOf(AppAction.stopTurn, covered), isA<Unavailable>());
  });

  test("a toggle is titled by which way it goes", () {
    expect(titleOf(Destination.toggleSidebar, facts), "Hide Sidebar");
    expect(
      titleOf(AppAction.pinChat, (
        front: true,
        chatOpen: true,
        pinned: true,
        running: false,
        sidebarShown: false,
        hasWorkspace: true,
        hasMemories: true,
        hasSettings: true,
      )),
      "Unpin Chat",
    );
  });

  test("an id names its item", () {
    for (final item in appItems) {
      expect(appItemNamed(item.id), item);
    }
  });
}
