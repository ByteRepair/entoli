import SwiftUI

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// What the shell draws, as Dart last said it, one published value per
/// concern; and the way back, [intent]. Holds nothing of its own: a snapshot
/// replaces what was there, and a tap is an intent Dart answers with the next
/// snapshot. See `lib/ui/shell/snapshots.dart`, whose maps these decode.
final class ShellModel: ObservableObject {
  private let channel: FlutterMethodChannel

  @Published var window = WindowState()
  @Published var sidebar = SidebarState()
  @Published var chatBar = ChatBarState()
  @Published var turn = TurnState()

  /// The composer's own object, so a keystroke redraws it and nothing else.
  private(set) lazy var composer = ComposerModel(shell: self)

  /// Told when the window's own state changes, for what SwiftUI cannot set:
  /// the window's appearance.
  var onWindow: ((WindowState) -> Void)?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  func apply(concern: String, value: Any?) {
    switch concern {
    case "window":
      if let state: WindowState = decode(value), state != window {
        window = state
        onWindow?(state)
      }
    case "sidebar":
      if let state: SidebarState = decode(value), state != sidebar { sidebar = state }
    case "chatBar":
      if let state: ChatBarState = decode(value), state != chatBar { chatBar = state }
    case "turn":
      if let state: TurnState = decode(value), state != turn { turn = state }
    case "composer":
      if let look: ComposerLook = decode(value) { composer.apply(look) }
    case "composerValue":
      if let value: ComposerValue = decode(value) { composer.apply(value) }
    case "composerFocus":
      composer.focus()
    default:
      break
    }
  }

  /// What the user did, for Dart to run: see `ShellBridge._run`. [done] is
  /// told what Dart answered once it has run: an error to show, or nil.
  func intent(
    _ name: String, _ args: [String: Any?] = [:], done: ((String?) -> Void)? = nil
  ) {
    intent(name, args) { done?($0 as? String) }
  }

  /// [intent], hearing whatever Dart answered.
  func intent(_ name: String, _ args: [String: Any?], answered: ((Any?) -> Void)?) {
    let args = args.mapValues { $0 ?? NSNull() }
    channel.invokeMethod("intent", arguments: ["name": name, "args": args]) { answer in
      answered?(answer)
    }
  }

  private var reported: EdgeInsets?

  /// How much of the Flutter view the shell's own bars cover, which Dart
  /// hands the conversation as padding so it scrolls under them.
  func insets(_ insets: EdgeInsets) {
    guard insets != reported else { return }
    reported = insets
    channel.invokeMethod(
      "insets",
      arguments: [
        "top": insets.top, "bottom": insets.bottom,
        "left": insets.leading, "right": insets.trailing,
      ])
  }

  private func decode<T: Decodable>(_ value: Any?) -> T? {
    guard let value, JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value)
    else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }
}

/// `WindowSnapshot`.
struct WindowState: Decodable, Equatable {
  var covered = false
  var sidebarShown = true
  var appearance: String?

  var colorScheme: ColorScheme? {
    switch appearance {
    case "light": .light
    case "dark": .dark
    default: nil
    }
  }
}

/// `ToolbarItem`.
struct ToolbarItemState: Decodable, Equatable, Identifiable {
  var id: String
  var label: String
  var symbol: String?
  var spinner = false
}

/// `ChatBarSnapshot`.
struct ChatBarState: Decodable, Equatable {
  var title = "Entoli"
  var subtitle = ""
  var expiresAt: Double?
  var items: [ToolbarItemState] = []

  var expires: Date? { expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
}
