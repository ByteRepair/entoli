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
  @Published var newChat = NewChatState()
  @Published var voice = VoiceState()
  @Published var palette = PaletteState()

  /// A strip of choices over the Flutter view, and who waits on its answer:
  /// see `Strip.swift`.
  @Published var strip: StripRequest?
  var stripReply: ((Any?) -> Void)?

  /// Asked of the split view where it is one column — an iPhone — so a chat
  /// opened or a new one started is shown rather than left behind the list.
  @Published private(set) var detailAsked = 0

  func showDetail() { detailAsked += 1 }

  /// The microphone's level: not published, being many times a second and
  /// read by the glow on each of its frames.
  let voiceLevel = VoiceLevel()

  /// The composer's own object, so a keystroke redraws it and nothing else.
  private(set) lazy var composer = ComposerModel(shell: self)

  /// Told when the window's own state changes, for what SwiftUI cannot set:
  /// the window's appearance.
  var onWindow: ((WindowState) -> Void)?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  /// A snapshot from Dart: [json] as its outbox compared it, or [value] for
  /// a one-off with nothing to compare.
  func apply(concern: String, value: Any?, json: String?) {
    func decode<T: Decodable>() -> T? {
      guard let data = json?.data(using: .utf8) else { return nil }
      return try? Self.decoder.decode(T.self, from: data)
    }
    switch concern {
    case "window":
      if let state: WindowState = decode(), state != window {
        window = state
        onWindow?(state)
      }
    case "sidebar":
      if let state: SidebarState = decode(), state != sidebar { sidebar = state }
    case "chatBar":
      if let state: ChatBarState = decode(), state != chatBar { chatBar = state }
    case "palette":
      if let state: PaletteState = decode(), state != palette { palette = state }
    case "voice":
      if let state: VoiceState = decode(), state != voice { voice = state }
    case "voiceLevel":
      voiceLevel.set(((value as? [String: Any])?["level"] as? NSNumber)?.doubleValue ?? 0)
    case "newChat":
      if let state: NewChatState = decode(), state != newChat { newChat = state }
    case "turn":
      if let state: TurnState = decode(), state != turn { turn = state }
    case "composer":
      if let look: ComposerLook = decode() { composer.apply(look) }
    case "composerValue":
      if let value: ComposerValue = decode() { composer.apply(value) }
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

  /// What the user did on one of the surfaces Dart keeps a stack of — the
  /// composer, the turn, the new-chat screen, voice mode, the toolbar — sent
  /// under its [concern] to the one on screen: see `ShellSlots`. [answered]
  /// hears what Dart answered.
  func say(
    _ concern: String, _ name: String, _ args: [String: Any?] = [:],
    answered: ((Any?) -> Void)? = nil
  ) {
    intent(
      concern, ["name": name, "args": args.mapValues { $0 ?? NSNull() }], answered: answered)
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

  private static let decoder = JSONDecoder()
}

extension Color {
  /// An ARGB the way Dart's `toARGB32` gives one.
  init(argb: Int) {
    self.init(
      red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255,
      blue: Double(argb & 0xFF) / 255, opacity: Double((argb >> 24) & 0xFF) / 255)
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
