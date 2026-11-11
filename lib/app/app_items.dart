import "../domain/availability.dart";

/// A key as the menus and the key handlers take it: the chord key (Cmd on
/// Apple's platforms, Ctrl elsewhere) plus [char], with Shift and Alt
/// (Option) as given. [char] is what the key types, lower case.
class AppKey {
  const AppKey(this.char, {this.shift = false, this.alt = false});

  final String char;
  final bool shift;
  final bool alt;
}

/// Everything the app can be told to do by name, wherever it is told: a key,
/// the menu bar, Shortcuts. An [AppAction], which the core runs, or a
/// [Destination], which the frontend on screen goes to. The name is the id,
/// so it is never renamed.
sealed class AppItem {
  /// The enum's name: what Shortcuts and the menu bar know it by.
  String get id;
  String get title;
  AppKey? get key;

  /// Runs with a page pushed over the chat pane. The rest would act on a pane
  /// nobody can see.
  bool get anywhere;
}

/// What changes what happens: run by the core, its availability the core's.
/// Where one needs an answer first (a name, a project, a confirmation), the
/// frontend asks in its own way and passes it on.
enum AppAction implements AppItem {
  newChat("New Chat", key: AppKey("n")),
  newAnonymousChat("New Anonymous Chat", key: AppKey("n", shift: true)),
  newOmadaChat("New Omada Chat", key: AppKey("n", alt: true)),
  pinChat("Pin Chat", key: AppKey("p", shift: true)),
  renameChat("Rename Chat…"),
  moveChat("Move Chat to Project…"),
  deleteChat("Delete Chat…"),
  stopTurn("Stop Turn", key: AppKey("."));

  const AppAction(this.title, {this.key});

  @override
  String get id => name;
  @override
  final String title;
  @override
  final AppKey? key;
  @override
  bool get anywhere => false;
}

/// Where the app can be taken: each frontend reaches every one through its
/// own exhaustive `navigate`, so a new one compiles in neither until both
/// can.
enum Destination implements AppItem {
  about("About Entoli", anywhere: true),
  settings("Settings…", key: AppKey(","), anywhere: true),
  profile("Profile…", anywhere: true),
  marketplace("Marketplace…", anywhere: true),
  backUp("Back Up…", anywhere: true),
  welcome("Welcome Tour", anywhere: true),
  keyboardShortcuts("Keyboard Shortcuts", anywhere: true),
  switchProject("Switch Project…", key: AppKey("k")),
  toggleSidebar("Toggle Sidebar", key: AppKey("s", alt: true)),
  chatSettings("Chat Settings…"),
  showPlan("Show Plan"),
  voiceMode("Voice Mode"),
  projectWorkspace("Workspace"),
  projectMemories("Memories"),
  projectSettings("Project Settings…");

  const Destination(this.title, {this.key, this.anywhere = false});

  @override
  String get id => name;
  @override
  final String title;
  @override
  final AppKey? key;
  @override
  final bool anywhere;
}

/// Every item, in the order Settings > Shortcuts and Shortcuts list them.
const List<AppItem> appItems = [
  Destination.about,
  Destination.settings,
  Destination.profile,
  Destination.marketplace,
  Destination.backUp,
  Destination.welcome,
  Destination.keyboardShortcuts,
  AppAction.newChat,
  AppAction.newAnonymousChat,
  AppAction.newOmadaChat,
  Destination.switchProject,
  Destination.toggleSidebar,
  AppAction.pinChat,
  AppAction.renameChat,
  AppAction.moveChat,
  AppAction.deleteChat,
  Destination.chatSettings,
  Destination.showPlan,
  Destination.voiceMode,
  AppAction.stopTurn,
  Destination.projectWorkspace,
  Destination.projectMemories,
  Destination.projectSettings,
];

/// The facts an item's availability and title are read from.
typedef AppFacts = ({
  bool front,
  bool chatOpen,
  bool pinned,
  bool running,
  bool sidebarShown,
  bool hasWorkspace,
  bool hasMemories,
  bool hasSettings,
});

/// Whether [item] can run now, and why not where it cannot: the one answer
/// the keys, the menus and Shortcuts all ask.
Availability availabilityOf(AppItem item, AppFacts facts) {
  if (!item.anywhere && !facts.front) {
    return const Unavailable("A page is open over the chat.");
  }
  Availability needs(bool ok, String why) =>
      ok ? const Available() : Unavailable(why);
  const noChat = "No chat is open.";
  return switch (item) {
    AppAction.pinChat ||
    AppAction.renameChat ||
    AppAction.moveChat ||
    AppAction.deleteChat ||
    Destination.chatSettings ||
    // The page says where a chat has none.
    Destination.showPlan => needs(facts.chatOpen, noChat),
    AppAction.stopTurn => needs(facts.running, "No turn is running."),
    Destination.projectWorkspace => needs(
      facts.hasWorkspace,
      "This project has no workspace.",
    ),
    Destination.projectMemories => needs(
      facts.hasMemories,
      "This project keeps no memories.",
    ),
    Destination.projectSettings => needs(
      facts.hasSettings,
      "This project has no settings.",
    ),
    _ => const Available(),
  };
}

/// [item]'s title, saying which way a toggle goes.
String titleOf(AppItem item, AppFacts facts) => switch (item) {
  AppAction.pinChat when facts.pinned => "Unpin Chat",
  Destination.toggleSidebar =>
    facts.sidebarShown ? "Hide Sidebar" : "Show Sidebar",
  _ => item.title,
};

/// What a menu is to the platform, which has its own of some: the app's
/// menu, File, View and Help are the platform's, the app's items added to
/// them; any other is a menu of the app's own. What the platform puts in
/// them itself (Hide, Quit, Full Screen, the Window menu) is its business.
enum MenuRole { app, file, view, help, own }

/// One menu of the bar: its items in groups.
class AppMenu {
  const AppMenu(this.title, this.role, this.groups);

  final String title;
  final MenuRole role;
  final List<List<AppItem>> groups;
}

/// The menu bar, as data: the one layout both frontends show. The app's
/// menu is titled with the app's name by the platform whatever this says.
const List<AppMenu> appMenus = [
  AppMenu("Entoli", MenuRole.app, [
    [Destination.about],
    [Destination.settings, Destination.profile, Destination.marketplace],
  ]),
  AppMenu("File", MenuRole.file, [
    [AppAction.newChat, AppAction.newAnonymousChat, AppAction.newOmadaChat],
    [Destination.switchProject],
    [Destination.backUp],
  ]),
  AppMenu("Chat", MenuRole.own, [
    [AppAction.pinChat, AppAction.renameChat, AppAction.moveChat],
    [
      Destination.chatSettings,
      Destination.showPlan,
      Destination.voiceMode,
      AppAction.stopTurn,
    ],
    [AppAction.deleteChat],
  ]),
  AppMenu("Project", MenuRole.own, [
    [
      Destination.projectWorkspace,
      Destination.projectMemories,
      Destination.projectSettings,
    ],
  ]),
  AppMenu("View", MenuRole.view, [
    [Destination.toggleSidebar],
  ]),
  AppMenu("Help", MenuRole.help, [
    [Destination.welcome, Destination.keyboardShortcuts],
  ]),
];

/// Whether [item] is in [appMenus], whose keys the menu bar holds where
/// there is one.
bool inAppMenus(AppItem item) =>
    appMenus.any((menu) => menu.groups.any((group) => group.contains(item)));

/// The item named [name], for an id from outside.
AppItem? appItemNamed(String name) =>
    appItems.where((item) => item.id == name).firstOrNull;
