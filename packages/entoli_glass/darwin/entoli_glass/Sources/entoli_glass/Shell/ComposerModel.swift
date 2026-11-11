import SwiftUI

#if os(iOS)
  import Flutter
  import UIKit
#else
  import AppKit
  import FlutterMacOS
#endif

extension ComposerSnapshot {
  /// No page has a composer yet.
  static let initial = ComposerSnapshot(
    present: false, mode: .message, canSend: false, queues: false,
    speaking: false, voice: false, attachments: [], menu: [], cards: [:])
}

/// What the text view is to the model: told a value Dart set, asked to take
/// the keyboard or give it up, and to draw its cards again when what they
/// look like changed.
protocol ComposerEditor: AnyObject {
  func apply(text: String, start: Int, end: Int)
  func focus(_ focused: Bool)
  func restyle()
}

/// The composer's state as Dart last said it, and the way back to Dart. Dart
/// decides — `ShellComposer` over the core's `ComposerModel`, which the
/// Flutter composer runs on too — and this draws what it was told, in its own
/// words, and says what the user did. Its own object rather than a field of [ShellModel], so a keystroke
/// redraws the composer and nothing else.
final class ComposerModel: ObservableObject {
  @Published private(set) var look = ComposerSnapshot.initial

  /// The menu row the arrows are on: the view's own, since only it moves it.
  @Published var highlighted = 0

  /// Whether the field is empty, for the hint drawn over it.
  @Published var empty = true

  /// The field's height as the text view measured it, held to [maxLines].
  @Published var fieldHeight: CGFloat = 22

  private weak var shell: ShellModel?

  /// The value Dart sent before the text view existed.
  private var pending: ComposerValueSnapshot?

  weak var editor: ComposerEditor? {
    didSet {
      if let value = pending, let editor {
        pending = nil
        editor.apply(text: value.text, start: Int(value.start), end: Int(value.end))
      }
    }
  }

  init(shell: ShellModel) {
    self.shell = shell
  }

  var present: Bool { look.present }
  var mode: InputMode { look.mode }
  var menu: [ComposerMenuItem] { look.menu }
  var callback: CallbackKind? { look.callback }
  var canSend: Bool { look.canSend }
  var queues: Bool { look.queues }
  var speaking: Bool { look.speaking }
  var voice: Bool { look.voice }
  /// How many lines the field grows to before it scrolls: two more per
  /// card, each taller than a line, up to four of them.
  var maxLines: Int { 6 + 2 * min(look.cards.count, 4) }
  var cwd: String? { look.cwd }
  var attachments: [ComposerAttachment] { look.attachments }

  /// The cards by their codes, as [look] last said them: made when they
  /// change rather than on every read, the field reading them once per
  /// character it draws.
  private(set) var cards: [UInt16: ComposerCard] = [:]

  /// The menu's agent faces by row, decoded when a snapshot arrives rather
  /// than on every body.
  private(set) var pictures: [Int: Image] = [:]

  /// The faces the menu showed last, by their PNG bytes.
  private var faces: [Data: Image] = [:]

  private static func image(_ png: Data) -> Image? {
    #if os(iOS)
      UIImage(data: png).map { Image(uiImage: $0) }
    #else
      NSImage(data: png).map { Image(nsImage: $0) }
    #endif
  }

  func apply(_ next: ComposerSnapshot) {
    guard next != look else { return }
    let restyle = next.mode != look.mode || next.cards != look.cards
    // A different list starts again at its first row; the same one keeps the
    // row the arrows are on — a face arriving for a row is the same list.
    if next.menu.map(\.name) != look.menu.map(\.name) { highlighted = 0 }
    // Each snapshot's bytes are a fresh object, so a face is known again by
    // its bytes and decoded only the first time.
    var decoded: [Data: Image] = [:]
    pictures = Dictionary(
      uniqueKeysWithValues: next.menu.enumerated().compactMap { row, item in
        guard let png = item.picture?.data else { return nil }
        guard let image = decoded[png] ?? faces[png] ?? Self.image(png) else { return nil }
        decoded[png] = image
        return (row, image)
      })
    faces = decoded
    if next.cards != look.cards {
      cards = Dictionary(
        next.cards.map { (UInt16(truncatingIfNeeded: $0.key), $0.value) },
        uniquingKeysWith: { first, _ in first })
    }
    look = next
    if restyle { editor?.restyle() }
  }

  /// The text and selection Dart and the field last agreed on, so a report
  /// that changes nothing is not sent: one keystroke both edits the text and
  /// moves the caret, and the field says so for each.
  private var known: (text: String, start: Int64, end: Int64)?

  /// The last revision applied: Dart sends a value only when it set one.
  private var revision: Int64 = -1

  /// A value Dart set: a completion taken, a message restored, a send.
  func apply(_ value: ComposerValueSnapshot) {
    guard value.revision != revision else { return }
    revision = value.revision
    known = (value.text, value.start, value.end)
    if let editor {
      editor.apply(text: value.text, start: Int(value.start), end: Int(value.end))
    } else {
      pending = value
    }
  }

  func focus(_ focused: Bool) {
    editor?.focus(focused)
  }

  /// The field took the keyboard, or gave it up.
  func focused(_ focused: Bool) {
    say?.focused(focused: focused) { _ in }
  }

  /// What the user did, to the composer on top in Dart.
  var say: ComposerIntents? { shell?.say.composer }

  /// The field changed, or its caret moved.
  func edited(text: String, start: Int, end: Int) {
    shown(text: text)
    let value = (text: text, start: Int64(start), end: Int64(end))
    if let known, known == value { return }
    known = value
    say?.edited(text: text, start: value.start, end: value.end) { _ in }
  }

  /// What the field now holds, for the hint over it: published only when
  /// that flips, not on every keystroke.
  func shown(text: String) {
    if empty != text.isEmpty { empty = text.isEmpty }
  }

  /// The field's measured height, after the update that measured it and on
  /// the view's own curve: the field grows a line at a time with everything
  /// else rather than jumping.
  func measured(height: CGFloat) {
    guard abs(fieldHeight - height) > 0.5 else { return }
    DispatchQueue.main.async {
      withAnimation(ComposerView.motion) { self.fieldHeight = height }
    }
  }

  /// Ask Dart to take files off the clipboard; [then] hears whether it did.
  func paste(then: @escaping (Bool) -> Void) {
    guard let say else { return then(false) }
    say.paste { then((try? $0.get()) ?? false) }
  }

  /// Move the menu's highlight, wrapping at either end.
  func move(_ delta: Int) {
    let count = look.menu.count
    guard count > 0 else { return }
    highlighted = (highlighted + delta + count) % count
  }

  func pickHighlighted() {
    let count = look.menu.count
    guard count > 0 else { return }
    say?.pick(index: Int64(highlighted % count)) { _ in }
  }
}
