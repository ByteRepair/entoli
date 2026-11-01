import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    // Before this returns, or the tap that launched the app reaches no
    // delegate and its chat never opens.
    UNUserNotificationCenter.current().delegate = RemindersPlugin.shared
    return launched
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    VoiceChannel.register(with: engineBridge)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RemindersPlugin") {
      RemindersPlugin.register(with: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppleFmChannel") {
      AppleFmChannel.register(with: registrar.messenger())
    }
    // The models run in the app's own process here: iOS cannot start one.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MlxChannel") {
      MlxChannel.register(with: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ClipboardChannel") {
      ClipboardChannel.register(with: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BrowserChannel") {
      BrowserChannel.register(with: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MenuChannel") {
      MenuChannel.shared.register(with: registrar.messenger())
    }
  }

  override func buildMenu(with builder: UIMenuBuilder) {
    super.buildMenu(with: builder)
    MenuChannel.shared.build(builder)
  }

  /// Every item of the app's menus: the item says which by its id.
  @objc func entoliMenuItem(_ sender: UICommand) {
    MenuChannel.shared.select(sender)
  }
}

/// The app's menus on iPadOS — the menu bar, and the keys an iPhone's
/// keyboard shows — which Flutter's engine draws on macOS alone. It speaks the
/// macOS engine's protocol, so Dart sends the same menus to both: `setMenus`
/// with the tree, `selectedCallback` back with an item's id. See
/// app_menu_bar.dart. In this file rather than its own so the Xcode project
/// needs no new entry.
final class MenuChannel {
  static let shared = MenuChannel()

  private var channel: FlutterMethodChannel?
  private var menus: [[String: Any]] = []

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "agent_chat/menu", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "Menu.setMenus" else { return result(FlutterMethodNotImplemented) }
      // Keyed by window, of which there is one.
      self?.menus = (call.arguments as? [String: Any])?["0"] as? [[String: Any]] ?? []
      UIMenuSystem.main.setNeedsRebuild()
      result(nil)
    }
    self.channel = channel
  }

  func select(_ command: UICommand) {
    guard let id = command.propertyList as? Int else { return }
    channel?.invokeMethod("Menu.selectedCallback", arguments: id)
  }

  /// The first menu is the app's own, so its items go into UIKit's; a menu
  /// titled as one of UIKit's goes at the top of it; the rest go before
  /// Window, in order. The system's Settings goes, the app's own taking ⌘,.
  func build(_ builder: UIMenuBuilder) {
    guard builder.system == .main, let app = menus.first else { return }
    builder.remove(menu: .preferences)
    builder.insertChild(menu(app, inline: true), atStartOfMenu: .application)
    let system: [String: UIMenu.Identifier] = [
      "File": .file, "Edit": .edit, "View": .view, "Window": .window, "Help": .help,
    ]
    for item in menus.dropFirst() {
      let label = item["label"] as? String ?? ""
      if let id = system[label] {
        builder.insertChild(menu(item, inline: true), atStartOfMenu: id)
      } else {
        builder.insertSibling(menu(item, inline: false), beforeMenu: .window)
      }
    }
  }

  /// One of Dart's menus: its dividers split it into inline groups, which is
  /// how UIKit draws a separator.
  private func menu(_ item: [String: Any], inline: Bool) -> UIMenu {
    var groups: [[UIMenuElement]] = [[]]
    for child in item["children"] as? [[String: Any]] ?? [] {
      if child["isDivider"] as? Bool == true {
        groups.append([])
      } else if let element = element(child) {
        groups[groups.count - 1].append(element)
      }
    }
    let children = groups.filter { !$0.isEmpty }.map {
      UIMenu(title: "", options: .displayInline, children: $0)
    }
    let label = item["label"] as? String ?? ""
    return UIMenu(
      title: inline ? "" : label,
      identifier: UIMenu.Identifier("io.byterepair.entoli.menu.\(label)"),
      options: inline ? .displayInline : [],
      children: children)
  }

  /// An item, a submenu, or nothing for an item only macOS provides.
  private func element(_ item: [String: Any]) -> UIMenuElement? {
    if item["platformProvidedMenu"] != nil { return nil }
    if item["children"] != nil { return menu(item, inline: false) }
    guard let id = item["id"] as? Int else { return nil }
    let title = item["label"] as? String ?? ""
    let action = #selector(AppDelegate.entoliMenuItem(_:))
    let command: UICommand
    if let trigger = item["shortcutTrigger"] as? Int,
       let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: trigger)) {
      command = UIKeyCommand(
        title: title, action: action, input: String(Character(scalar)),
        modifierFlags: modifiers(item["shortcutModifiers"] as? Int ?? 0), propertyList: id)
    } else {
      command = UICommand(title: title, action: action, propertyList: id)
    }
    if item["enabled"] as? Bool != true { command.attributes = .disabled }
    return command
  }

  /// Flutter's modifier bits: meta, shift, alt, control.
  private func modifiers(_ bits: Int) -> UIKeyModifierFlags {
    var flags: UIKeyModifierFlags = []
    if bits & 1 != 0 { flags.insert(.command) }
    if bits & 2 != 0 { flags.insert(.shift) }
    if bits & 4 != 0 { flags.insert(.alternate) }
    if bits & 8 != 0 { flags.insert(.control) }
    return flags
  }
}

/// The copy with formatting, which Flutter's own clipboard call cannot make:
/// it writes plain text only. And an image a paste brings, which it cannot
/// read. See rich_clipboard.dart and clipboard_files.dart. In this file rather
/// than its own so the Xcode project needs no new entry.
enum ClipboardChannel {
  private static var channel: FlutterMethodChannel?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "agent_chat/clipboard", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "setHtml":
        guard let args = call.arguments as? [String: Any],
              let plain = args["plain"] as? String, let html = args["html"] as? String
        else { return result(FlutterError(code: "bad-args", message: "plain and html", details: nil)) }
        var item: [String: Any] = ["public.html": html, "public.utf8-plain-text": plain]
        // Pages and Notes read RTF and not HTML, and fall back to the plain
        // entry — which is markdown — without it. RTFD too: it carries a
        // formula's picture, which RTF drops.
        if let text = attributedOf(html) {
          let all = NSRange(location: 0, length: text.length)
          for (type, kind) in [
            ("com.apple.flat-rtfd", NSAttributedString.DocumentType.rtfd),
            ("public.rtf", NSAttributedString.DocumentType.rtf),
          ] {
            item[type] = try? text.data(from: all, documentAttributes: [.documentType: kind])
          }
        }
        UIPasteboard.general.items = [item]
        result(nil)
      case "readFiles":
        let pasteboard = UIPasteboard.general
        // The has- checks raise no paste prompt; reading the image does, so
        // a text paste never asks.
        guard pasteboard.hasImages, !pasteboard.hasStrings,
              let png = pasteboard.data(forPasteboardType: "public.png")
                ?? pasteboard.image?.pngData()
        else { return result([]) }
        result([["bytes": FlutterStandardTypedData(bytes: png)]])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// [html] read by UIKit's own HTML reader — a formula's picture becomes
  /// an attachment — for the RTF a target that reads no HTML keeps. Nil
  /// where it will not read it.
  private static func attributedOf(_ html: String) -> NSAttributedString? {
    guard let data = html.data(using: .utf8) else { return nil }
    return try? NSAttributedString(
      data: data,
      options: [
        .documentType: NSAttributedString.DocumentType.html,
        .characterEncoding: String.Encoding.utf8.rawValue,
      ],
      documentAttributes: nil)
  }
}
