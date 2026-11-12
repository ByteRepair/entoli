import SwiftUI

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// What the shell draws, as Dart last said it, one observed value per
/// concern; and the way back, [say]. Holds nothing of its own: a snapshot
/// replaces what was there, and a tap is an intent Dart answers with the next
/// snapshot. Both are the protocol `pigeons/shell.dart` generates, this the
/// [NativeShell] end of it.
@Observable final class ShellModel {
  /// The one, made as the plugin registers: there is one engine and one
  /// window.
  static var shared: ShellModel?

  var window = WindowSnapshot.initial
  var sidebar = SidebarSnapshot.initial
  var chatBar = ChatBarSnapshot.initial
  var pageBar = TitleBarSnapshot.absent
  var turn = TurnSnapshot.initial
  var newChat = NewChatSnapshot.initial
  var voice = VoiceSnapshot.initial
  var palette = PaletteSnapshot.initial
  var foot = ChatFootSnapshot(deviceOffline: false, bar: .none)

  /// The line said to the user now, if any: up for a few seconds, then gone,
  /// a newer one taking its place.
  var notice: Notice?

  /// The agent's browser as the user watches it, and its latest frame.
  var browser = BrowserViewSnapshot(present: false, title: "", open: false, hidden: false, window: false)
  var browserFrame: BrowserFrame?

  /// What the user did, for Dart to run: one object per surface, each a
  /// method per intent it can send, answered by whichever widget draws that
  /// surface in Dart (`ShellAnswers`).
  let say: ShellIntents

  /// A strip of choices over the Flutter view, and who waits on its answer:
  /// see `Strip.swift`.
  var strip: StripRequest?

  /// The dialog Dart asked, and who waits on its answer.
  var dialog: DialogRequest?
  @ObservationIgnored var dialogReply: ((DialogAnswer) -> Void)?
  @ObservationIgnored var stripReply: ((Int64?) -> Void)?

  /// Which of the two an iPhone's drawer shows (`Drawer.swift`). The detail
  /// to begin with, nothing selected being the new-chat screen as it is in
  /// the Flutter app; the list when its button or a swipe asks for it; the
  /// detail again once a chat, a new one, a page or a project is picked from
  /// it, as the Flutter drawer closes on each, or a swipe puts it back.
  var compactColumn = NavigationSplitViewColumn.detail

  /// Set only where it changes: an observed write tells every view that
  /// reads it, equal or not. Animated, so the drawer slides for a button as
  /// it does for a swipe.
  func showDetail() { show(.detail) }
  func showSidebar() { show(.sidebar) }

  private func show(_ column: NavigationSplitViewColumn) {
    guard compactColumn != column else { return }
    withAnimation(.smooth(duration: 0.35)) { compactColumn = column }
  }

  /// The microphone's level: not observed, being many times a second and
  /// read by the glow on each of its frames.
  let voiceLevel = VoiceLevel()

  /// The composer's own object, which a keystroke changes and nothing else
  /// reads.
  @ObservationIgnored private(set) lazy var composer = ComposerModel(shell: self)

  /// Which frontend the core picked at launch: this one (true) or Flutter's
  /// alone. Nil until Dart has said, the window showing only its colour.
  private(set) var frontend: Bool?

  /// The app proper is up: its window snapshot has come, which Dart sends
  /// only once the welcome tour and first-run setup are behind it. Until
  /// then the chrome stays out of the way, so nothing of it bypasses them.
  private(set) var ready = false

  init(messenger: FlutterBinaryMessenger) {
    say = ShellIntents(messenger: messenger)
  }

  @ObservationIgnored private var reported: EdgeInsets?

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
  func foot(snapshot: ChatFootSnapshot) throws { foot = snapshot }

  func browser(snapshot: BrowserViewSnapshot) throws {
    browser = snapshot
    if !snapshot.present { browserFrame = nil }
  }

  func browserFrame(frame: BrowserFrameSnapshot) throws {
    guard browser.present, let decoded = BrowserFrame(frame) else { return }
    browserFrame = decoded
  }

  func notice(message: String) throws {
    let said = Notice(message: message)
    withAnimation(.snappy) { notice = said }
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(4))
      guard self?.notice?.id == said.id else { return }
      withAnimation(.snappy) { self?.notice = nil }
    }
  }

  func voiceLevel(level: Double) throws { voiceLevel.set(level) }

  func composerFocus(focused: Bool) throws { composer.focus(focused) }

  func strip(request: ChoiceStrip, completion: @escaping (Result<Int64?, Error>) -> Void) {
    showStrip(request) { completion(.success($0)) }
  }

  func dialog(request: DialogRequest, completion: @escaping (Result<DialogAnswer, Error>) -> Void) {
    // One at a time: the one open is answered as dismissed.
    dialogReply?(DialogAnswer(agreed: false))
    dialogReply = { completion(.success($0)) }
    dialog = request
  }

  /// Answers the dialog open, and takes it down.
  func answer(_ answer: DialogAnswer) {
    let reply = dialogReply
    dialogReply = nil
    dialog = nil
    reply?(answer)
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
  let foot: ChatFootIntents
  let browser: BrowserIntents

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
    foot = ChatFootIntents(binaryMessenger: messenger)
    browser = BrowserIntents(binaryMessenger: messenger)
  }
}

extension WindowSnapshot {
  static let initial = WindowSnapshot(covered: false, overlaid: false, sidebarShown: true)

  var colorScheme: ColorScheme? { dark.map { $0 ? .dark : .light } }
}
