import SwiftUI

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// The app's menus as Dart last sent them, and the way back: one source for
/// both Runners (`sharedDarwinSource`). The menu bar itself is SwiftUI's —
/// `AppCommands`, in the app's `.commands` — so the platform puts in what it
/// always does (Hide, Quit, Full Screen, the Window menu) and this adds the
/// app's items to it.
public final class MenuModel: NSObject, ObservableObject, NativeMenuBar, FlutterPlugin {
  public static let shared = MenuModel()

  @Published var menus: [NativeMenu] = []
  private var picks: NativeMenuPicks?

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    shared.picks = NativeMenuPicks(binaryMessenger: messenger)
    NativeMenuBarSetup.setUp(binaryMessenger: messenger, api: shared)
    #if os(macOS)
      // SwiftUI fills a menu when it is opened, and a shortcut finds only
      // what is filled: every chord fills them first.
      NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if event.modifierFlags.contains(.command) {
          for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
            menu.delegate?.menuNeedsUpdate?(menu)
          }
        }
        return event
      }
    #endif
  }

  func show(menus: [NativeMenu]) throws { self.menus = menus }

  func pick(_ id: String) { picks?.picked(id: id) { _ in } }

  func groups(_ role: NativeMenuRole) -> [[NativeMenuItem]] {
    menus.first { $0.role == role }?.groups ?? []
  }

  /// The app's own menus, in order.
  var own: [NativeMenu] { menus.filter { $0.role == .own } }
}

/// The menu bar's items, for the app's `.commands`. Each holds its keys as a
/// keyboard shortcut, so the menu runs them and the Flutter key handler
/// stands down for them.
public struct AppCommands: Commands {
  @ObservedObject var model: MenuModel

  public init(model: MenuModel = .shared) { self.model = model }

  public var body: some Commands {
    // The app's menu: About in About's place, the rest in Settings'. Dart's
    // Settings replaces the platform's: iOS's opens the Settings app, and a
    // Mac's scene item is removed in the Runner.
    CommandGroup(replacing: .appInfo) {
      MenuGroups(model: model, groups: Array(model.groups(.app).prefix(1)))
    }
    CommandGroup(replacing: .appSettings) {
      MenuGroups(model: model, groups: Array(model.groups(.app).dropFirst()))
    }
    CommandGroup(replacing: .newItem) {
      // A window app's File menu is made only if this has something in it
      // at launch, before Dart has sent anything: a blank item holds the place.
      if model.menus.isEmpty { Button("") {}.disabled(true) }
      MenuGroups(model: model, groups: model.groups(.file))
    }
    CommandGroup(before: .sidebar) {
      MenuGroups(model: model, groups: model.groups(.view))
    }
    CommandGroup(replacing: .help) {
      MenuGroups(model: model, groups: model.groups(.help))
    }
    // A menu bar is a fixed list of declarations, so each of the app's own
    // menus has a slot.
    OwnMenu(model: model, index: 0)
    OwnMenu(model: model, index: 1)
    OwnMenu(model: model, index: 2)
    OwnMenu(model: model, index: 3)
  }
}

struct OwnMenu: Commands {
  @ObservedObject var model: MenuModel
  let index: Int

  var body: some Commands {
    if index < model.own.count {
      CommandMenu(model.own[index].title) {
        MenuGroups(model: model, groups: model.own[index].groups)
      }
    }
  }
}

/// Groups of items, a divider between each.
struct MenuGroups: View {
  let model: MenuModel
  let groups: [[NativeMenuItem]]

  var body: some View {
    ForEach(Array(groups.enumerated()), id: \.offset) { i, group in
      if i > 0 { Divider() }
      ForEach(group, id: \.id) { item in
        Button { model.pick(item.id) } label: {
          if let symbol = item.symbol {
            Label(item.title, systemImage: symbol)
          } else {
            Text(item.title)
          }
        }
        .keyboardShortcut(item.shortcut)
        .disabled(!item.enabled)
      }
    }
  }
}

extension NativeMenuItem {
  /// The chord key and [key], with Shift and Option as given; none for an
  /// item with no keys.
  var shortcut: KeyboardShortcut? {
    guard let key = key?.first else { return nil }
    var modifiers: EventModifiers = .command
    if shift { modifiers.insert(.shift) }
    if alt { modifiers.insert(.option) }
    return KeyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
  }
}
