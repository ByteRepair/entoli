import SwiftUI

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// What the shell draws, as Dart last said it, one published value per
/// concern; and the way back, [say]. Holds nothing of its own: a snapshot
/// replaces what was there, and a tap is an intent Dart answers with the next
/// snapshot. Both are the protocol `pigeons/shell.dart` generates, this the
/// [NativeShell] end of it.
final class ShellModel: ObservableObject {
  /// The one, made as the plugin registers: there is one engine and one
  /// window.
  static var shared: ShellModel?

  @Published var window = WindowSnapshot.initial
  @Published var sidebar = SidebarSnapshot.initial
  @Published var chatBar = ChatBarSnapshot.initial
  @Published var pageBar = TitleBarSnapshot.absent
  @Published var turn = TurnSnapshot.initial
  @Published var newChat = NewChatSnapshot.initial
  @Published var voice = VoiceSnapshot.initial
  @Published var palette = PaletteSnapshot.initial

  /// What the user did, for Dart to run: one object per surface, each a
  /// method per intent it can send, answered by whichever widget draws that
  /// surface in Dart (`ShellAnswers`).
  let say: ShellIntents

  /// A strip of choices over the Flutter view, and who waits on its answer:
  /// see `Strip.swift`.
  @Published var strip: StripRequest?
  var stripReply: ((Int64?) -> Void)?

  /// Which column the split view shows where it is one column — an iPhone.
  /// The detail to begin with, nothing selected being the new-chat screen
  /// as it is in the Flutter app; the list when its button or the system's
  /// back gesture asks for it; the detail again once a chat, a new one, a
  /// page or a project is picked from it, as the Flutter drawer closes on
  /// each. The split view writes it back as the user moves between the two.
  @Published var compactColumn = NavigationSplitViewColumn.detail

  /// Set only where it changes: the model is every view's, and a write it
  /// publishes redraws them all.
  func showDetail() { if compactColumn != .detail { compactColumn = .detail } }
  func showSidebar() { if compactColumn != .sidebar { compactColumn = .sidebar } }

  /// The microphone's level: not published, being many times a second and
  /// read by the glow on each of its frames.
  let voiceLevel = VoiceLevel()

  /// The composer's own object, so a keystroke redraws it and nothing else.
  private(set) lazy var composer = ComposerModel(shell: self)

  /// Which frontend the core picked at launch: this one (true) or Flutter's
  /// alone. Nil until Dart has said, the window showing only its colour.
  @Published private(set) var frontend: Bool?

  /// The app proper is up: its window snapshot has come, which Dart sends
  /// only once the welcome tour and first-run setup are behind it. Until
  /// then the chrome stays out of the way, so nothing of it bypasses them.
  @Published private(set) var ready = false

  init(messenger: FlutterBinaryMessenger) {
    say = ShellIntents(messenger: messenger)
  }

  private var reported: EdgeInsets?

  /// How much of the Flutter view the shell's own bars cover, which Dart
  /// hands the conversation as padding so it scrolls under them.
  func insets(_ insets: EdgeInsets) {
    guard insets != reported else { return }
    reported = insets
    say.window.insets(
      left: insets.leading, top: insets.top, right: insets.trailing, bottom: insets.bottom
    ) { _ in }
  }
}

/// A snapshot from Dart replaces what was there: Dart sends one only when it
/// changed.
extension ShellModel: NativeShell {
  func shell(on: Bool) throws {
    if frontend == nil { frontend = on }
  }

  func window(snapshot: WindowSnapshot) throws {
    window = snapshot
    if !ready { ready = true }
  }

  func sidebar(snapshot: SidebarSnapshot) throws { sidebar = snapshot }
  func chatBar(snapshot: ChatBarSnapshot) throws { chatBar = snapshot }
  func pageBar(snapshot: TitleBarSnapshot) throws { pageBar = snapshot }
  func composer(snapshot: ComposerSnapshot) throws { composer.apply(snapshot) }
  func composerValue(snapshot: ComposerValueSnapshot) throws { composer.apply(snapshot) }
  func turn(snapshot: TurnSnapshot) throws { turn = snapshot }
  func newChat(snapshot: NewChatSnapshot) throws { newChat = snapshot }
  func voice(snapshot: VoiceSnapshot) throws { voice = snapshot }
  func palette(snapshot: PaletteSnapshot) throws { palette = snapshot }

  func voiceLevel(level: Double) throws { voiceLevel.set(level) }

  func composerFocus(focused: Bool) throws { composer.focus(focused) }

  func strip(request: ChoiceStrip, completion: @escaping (Result<Int64?, Error>) -> Void) {
    showStrip(request) { completion(.success($0)) }
  }
}

/// The intents, one object per surface. A call whose answer nobody waits on
/// passes `{ _ in }`: Dart answers nothing, or no surface was on top to.
struct ShellIntents {
  let window: WindowEvents
  let sidebar: SidebarIntents
  let palette: PaletteIntents
  let composer: ComposerIntents
  let turn: TurnIntents
  let newChat: NewChatIntents
  let voice: VoiceIntents
  /// The chat's title bar, and a Flutter page's: one view draws both.
  let chatBar: ChatBarPresses
  let pageBar: TitleBarIntents

  init(messenger: FlutterBinaryMessenger) {
    window = WindowEvents(binaryMessenger: messenger)
    sidebar = SidebarIntents(binaryMessenger: messenger)
    palette = PaletteIntents(binaryMessenger: messenger)
    composer = ComposerIntents(binaryMessenger: messenger)
    turn = TurnIntents(binaryMessenger: messenger)
    newChat = NewChatIntents(binaryMessenger: messenger)
    voice = VoiceIntents(binaryMessenger: messenger)
    chatBar = ChatBarPresses(intents: ChatBarIntents(binaryMessenger: messenger))
    pageBar = TitleBarIntents(binaryMessenger: messenger, messageChannelSuffix: "pageBar")
  }
}

extension WindowSnapshot {
  static let initial = WindowSnapshot(covered: false, sidebarShown: true)

  var colorScheme: ColorScheme? { dark.map { $0 ? .dark : .light } }
}
