#if os(iOS)
  import Flutter
  import UIKit
#else
  import AppKit
  import FlutterMacOS
#endif

/// The app's menu bar, one source for both Runners (`sharedDarwinSource`):
/// Dart sends the menus as data with `show`, and an item picked goes back by
/// its id. macOS sets `NSApp.mainMenu`; iPadOS builds through `UIMenuBuilder`,
/// which an iPhone answers with its keys. Each item carries its keys as the
/// platform's own key equivalent, so the menu holds them and the app's key
/// handler stands down for them.
public final class EntoliMenuPlugin: NSObject, FlutterPlugin, NativeMenuBar {
  public static let shared = EntoliMenuPlugin()

  private var picks: NativeMenuPicks?
  private var menus: [NativeMenu] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    shared.picks = NativeMenuPicks(binaryMessenger: messenger)
    NativeMenuBarSetup.setUp(binaryMessenger: messenger, api: shared)
  }

  func show(menus: [NativeMenu]) throws {
    self.menus = menus
    #if os(iOS)
      UIMenuSystem.main.setNeedsRebuild()
    #else
      NSApp.mainMenu = mainMenu()
    #endif
  }

  private func picked(_ id: String) {
    picks?.picked(id: id) { _ in }
  }

  #if os(iOS)
    /// From the app delegate's `buildMenu(with:)`, which UIKit asks only of
    /// the app's own responders. The first menu's items go into UIKit's
    /// application menu; a menu titled as one of UIKit's goes at the top of
    /// it; the rest go before Window, in order. The system's Settings goes,
    /// the app's own taking ⌘,.
    public func build(_ builder: UIMenuBuilder) {
      guard builder.system == .main, let app = menus.first else { return }
      builder.remove(menu: .preferences)
      builder.insertChild(menu(app, inline: true), atStartOfMenu: .application)
      let system: [String: UIMenu.Identifier] = [
        "File": .file, "Edit": .edit, "View": .view, "Window": .window, "Help": .help,
      ]
      for item in menus.dropFirst() where !item.groups.isEmpty {
        if let id = system[item.title] {
          builder.insertChild(menu(item, inline: true), atStartOfMenu: id)
        } else {
          builder.insertSibling(menu(item, inline: false), beforeMenu: .window)
        }
      }
    }

    /// From the app delegate's action for every item: the item says which by
    /// its id.
    public func select(_ command: UICommand) {
      guard let id = command.propertyList as? String else { return }
      picked(id)
    }

    private func menu(_ menu: NativeMenu, inline: Bool) -> UIMenu {
      let groups = menu.groups.map { group in
        UIMenu(title: "", options: .displayInline, children: group.map(command))
      }
      return UIMenu(
        title: inline ? "" : menu.title,
        identifier: UIMenu.Identifier("io.byterepair.entoli.menu.\(menu.title)"),
        options: inline ? .displayInline : [],
        children: groups)
    }

    private func command(_ item: NativeMenuItem) -> UIMenuElement {
      let action = Selector(("entoliMenuItem:"))
      let command: UICommand
      if let key = item.key {
        var flags: UIKeyModifierFlags = .command
        if item.shift { flags.insert(.shift) }
        if item.alt { flags.insert(.alternate) }
        command = UIKeyCommand(
          title: item.title, action: action, input: key, modifierFlags: flags,
          propertyList: item.id)
      } else {
        command = UICommand(title: item.title, action: action, propertyList: item.id)
      }
      if !item.enabled { command.attributes = .disabled }
      return command
    }
  #else
    /// The whole bar: the app's menu titled with the app's name, Window and
    /// Help given to AppKit as its own so it fills them as it does.
    private func mainMenu() -> NSMenu {
      let bar = NSMenu()
      for (i, menu) in menus.enumerated() {
        let title = i == 0 ? ProcessInfo.processInfo.processName : menu.title
        let submenu = NSMenu(title: title)
        for (g, group) in menu.groups.enumerated() {
          if g > 0 { submenu.addItem(.separator()) }
          for item in group { submenu.addItem(self.item(item)) }
        }
        if !menu.system.isEmpty, !menu.groups.isEmpty { submenu.addItem(.separator()) }
        for system in menu.system { add(system, to: submenu) }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = submenu
        bar.addItem(holder)
        switch menu.title {
        case "Window": NSApp.windowsMenu = submenu
        case "Help": NSApp.helpMenu = submenu
        default: break
        }
      }
      return bar
    }

    private func item(_ item: NativeMenuItem) -> NSMenuItem {
      let menuItem = NSMenuItem(
        title: item.title, action: item.enabled ? #selector(choose(_:)) : nil,
        keyEquivalent: item.key ?? "")
      var mask: NSEvent.ModifierFlags = .command
      if item.shift { mask.insert(.shift) }
      if item.alt { mask.insert(.option) }
      menuItem.keyEquivalentModifierMask = mask
      menuItem.target = self
      menuItem.representedObject = item.id
      return menuItem
    }

    @objc private func choose(_ sender: NSMenuItem) {
      if let id = sender.representedObject as? String { picked(id) }
    }

    private func add(_ system: NativeSystemItem, to menu: NSMenu) {
      let app = ProcessInfo.processInfo.processName
      func add(_ title: String, _ action: Selector, _ key: String = "",
        _ mask: NSEvent.ModifierFlags = .command)
      {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mask
        menu.addItem(item)
      }
      switch system {
      case .services:
        let services = NSMenu(title: "Services")
        let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        item.submenu = services
        menu.addItem(item)
        NSApp.servicesMenu = services
        menu.addItem(.separator())
      case .hide: add("Hide \(app)", #selector(NSApplication.hide(_:)), "h")
      case .hideOthers:
        add(
          "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
          [.command, .option])
      case .showAll: add("Show All", #selector(NSApplication.unhideAllApplications(_:)))
      case .quit:
        menu.addItem(.separator())
        add("Quit \(app)", #selector(NSApplication.terminate(_:)), "q")
      case .toggleFullScreen:
        add("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
      case .minimize: add("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
      case .zoom: add("Zoom", #selector(NSWindow.performZoom(_:)))
      case .arrangeInFront:
        menu.addItem(.separator())
        add("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
      }
    }
  #endif
}
