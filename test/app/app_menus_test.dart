import "package:agent_chat/app/app_items.dart";
import "package:agent_chat/app/app_menus.dart";
import "package:entoli_core/model/menu_bar.dart";
import "package:flutter_test/flutter_test.dart";

class _Bar implements MenuBarHost {
  List<MenuBarMenu> shown = [];
  void Function(String id)? picked;

  @override
  void show(List<MenuBarMenu> menus) => shown = menus;

  @override
  set onPicked(void Function(String id)? picked) => this.picked = picked;
}

void main() {
  test("the bar is sent each item titled, greyed and keyed", () {
    final bar = _Bar();
    HostAppMenus(bar).show(
      appMenus,
      title: (item) => "T ${item.id}",
      enabled: (item) => item != Destination.about,
    );
    expect(bar.shown.map((m) => m.role), [
      for (final m in appMenus) MenuBarRole.values.byName(m.role.name),
    ]);
    final items = {
      for (final m in bar.shown)
        for (final g in m.groups)
          for (final i in g) i.id: i,
    };
    expect(items["about"]!.enabled, isFalse);
    expect(items["settings"]!.symbol, "gearshape");
    expect(items["settings"]!.title, "T settings");
    final newChat = items[AppAction.newChat.id]!;
    expect(newChat.key, AppAction.newChat.key?.char);
    expect(newChat.shift, AppAction.newChat.key?.shift ?? false);
  });

  test("a pick reaches the app as its item, and an unknown id as nothing", () {
    final bar = _Bar();
    final picks = <AppItem>[];
    HostAppMenus(bar).onPicked = picks.add;
    bar.picked!("settings");
    bar.picked!("no-such-item");
    expect(picks, [Destination.settings]);
    HostAppMenus(bar).onPicked = null;
    expect(bar.picked, isNull);
  });
}
