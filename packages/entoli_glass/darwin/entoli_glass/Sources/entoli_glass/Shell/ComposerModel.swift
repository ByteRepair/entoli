import SwiftUI

enum ComposerMode: String {
  case message, shell, callback
}

/// A card in the field: what one embed character draws as.
struct ComposerCard: Equatable {
  var title: String?
  var body: String
}

/// One row of the `/` or `@` menu.
struct ComposerOption: Identifiable, Equatable {
  let id: Int
  var label: String
  var hint: String?
  var detail: String?
}

/// `ComposerSnapshot`.
struct ComposerLook: Decodable, Equatable {
  struct Attachment: Decodable, Equatable, Hashable {
    var name: String
    var image: Bool
  }

  struct Option: Decodable, Equatable {
    var label: String
    var hint: String?
    var description: String?
  }

  struct Card: Decodable, Equatable {
    var code: Int
    var title: String?
    var body: String
  }

  var present = false
  var mode = "message"
  var hint = ""
  var sendLabel = "Send"
  var canSend = false
  var queues = false
  var speaking = false
  var voice = false
  var maxLines = 6
  var attachments: [Attachment] = []
  var menu: [Option] = []
  var cwd: String?
  var cards: [Card] = []
  var accent = 0xFF00_7AFF
  var dark = false
}

/// `ComposerValueSnapshot`.
struct ComposerValue: Decodable, Equatable {
  var text: String
  var start: Int
  var end: Int
}

/// What the text view is to the model: told a value Dart set, asked to take
/// the caret, and to draw its cards again when what they look like changed.
protocol ComposerEditor: AnyObject {
  func apply(text: String, start: Int, end: Int)
  func focus()
  func restyle()
}

/// The composer's state as Dart last said it, and the way back to Dart. Dart
/// decides — `ShellComposer` over the same `ComposerLogic` the Flutter
/// composer uses — and this draws what it was told and says what the user
/// did. Its own object rather than a field of [ShellModel], so a keystroke
/// redraws the composer and nothing else.
final class ComposerModel: ObservableObject {
  @Published private(set) var look = ComposerLook()

  /// The menu row the arrows are on: the view's own, since only it moves it.
  @Published var highlighted = 0

  /// Whether the field is empty, for the hint drawn over it.
  @Published var empty = true

  /// The field's height as the text view measured it, held to [maxLines].
  @Published var fieldHeight: CGFloat = 22

  private weak var shell: ShellModel?

  /// The value Dart sent before the text view existed.
  private var pending: ComposerValue?

  weak var editor: ComposerEditor? {
    didSet {
      if let value = pending, let editor {
        pending = nil
        editor.apply(text: value.text, start: value.start, end: value.end)
      }
    }
  }

  init(shell: ShellModel) {
    self.shell = shell
  }

  var present: Bool { look.present }
  var mode: ComposerMode { ComposerMode(rawValue: look.mode) ?? .message }
  var hint: String { look.hint }
  var sendLabel: String { look.sendLabel }
  var canSend: Bool { look.canSend }
  var queues: Bool { look.queues }
  var speaking: Bool { look.speaking }
  var voice: Bool { look.voice }
  var maxLines: Int { look.maxLines }
  var dark: Bool { look.dark }
  var cwd: String? { look.cwd }
  var attachments: [ComposerLook.Attachment] { look.attachments }

  var accent: Color { Color(argb: look.accent) }

  /// The menu's rows and the cards by their codes, as [look] last said them:
  /// made when it changes rather than on every read, the field reading the
  /// cards once per character it draws.
  private(set) var menu: [ComposerOption] = []
  private(set) var cards: [UInt16: ComposerCard] = [:]

  func apply(_ next: ComposerLook) {
    guard next != look else { return }
    let restyle = next.mode != look.mode || next.dark != look.dark || next.cards != look.cards
      || next.accent != look.accent
    // A different list starts again at its first row; the same one keeps the
    // row the arrows are on.
    if next.menu != look.menu {
      highlighted = 0
      menu = next.menu.enumerated().map { i, option in
        ComposerOption(id: i, label: option.label, hint: option.hint, detail: option.description)
      }
    }
    if next.cards != look.cards {
      cards = Dictionary(
        next.cards.map {
          (UInt16(truncatingIfNeeded: $0.code), ComposerCard(title: $0.title, body: $0.body))
        },
        uniquingKeysWith: { first, _ in first })
    }
    look = next
    if restyle { editor?.restyle() }
  }

  /// The value Dart and the field last agreed on, so a report that changes
  /// nothing is not sent: one keystroke both edits the text and moves the
  /// caret, and the field says so for each.
  private var known: ComposerValue?

  /// A value Dart set: a completion taken, a message restored, a send.
  func apply(_ value: ComposerValue) {
    known = value
    if let editor {
      editor.apply(text: value.text, start: value.start, end: value.end)
    } else {
      pending = value
    }
  }

  func focus() {
    editor?.focus()
  }

  /// Tell Dart something happened; [then] hears what it answered.
  func say(_ name: String, _ args: [String: Any?] = [:], then: ((Any?) -> Void)? = nil) {
    shell?.say("composer", name, args, answered: then)
  }

  /// The field changed, or its caret moved.
  func edited(text: String, start: Int, end: Int) {
    shown(text: text)
    let value = ComposerValue(text: text, start: start, end: end)
    guard value != known else { return }
    known = value
    say("edited", ["text": text, "start": start, "end": end])
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
    say("paste") { then($0 as? Bool ?? false) }
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
    say("pick", ["index": highlighted % count])
  }
}
