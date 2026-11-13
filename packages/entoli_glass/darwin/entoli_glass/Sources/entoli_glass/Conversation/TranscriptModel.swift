import SwiftUI

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// The conversation as Dart last said it: every row's key in order and the
/// rows themselves, the open detail, and the formulas' pictures. Holds
/// nothing of its own — a snapshot names the rows that changed, and the rest
/// stand — and says back what the user did through [say]. The
/// [NativeTranscript] end of `pigeons/transcript.dart`.
@Observable final class TranscriptModel {
  static var shared: TranscriptModel?

  /// The chat shown; nil while the conversation is Flutter's or not there.
  private(set) var chatId: String?
  private(set) var order: [String] = []
  /// Each row observed on its own, so a row that changed redraws alone.
  private(set) var rows: [String: RowEntry] = [:]
  /// Open but still being read, so an empty list is not an empty chat.
  private(set) var loading = false
  private(set) var reactions: [ReactionChoice] = []
  private(set) var chapters: [ChapterSnapshot] = []
  var detail = DetailSnapshot(
    present: false, title: "", statusError: false, sections: [], actions: [], mono: false,
    live: false)

  /// Each formula's picture by id, kept for the life of the engine: a
  /// formula is sent once.
  @ObservationIgnored private(set) var formulas: [Int64: Formula] = [:]

  /// Bumped as pictures land, so a row waiting on one redraws.
  private(set) var formulasLanded = 0

  let say: TranscriptIntents
  /// Markdown outside the conversation: a file, a skill, a page of the app's.
  let documents: DocumentIntents

  init(messenger: FlutterBinaryMessenger) {
    say = TranscriptIntents(binaryMessenger: messenger)
    documents = DocumentIntents(binaryMessenger: messenger)
  }

  var present: Bool { chatId != nil }
}

extension TranscriptModel: NativeTranscript {
  func conversation(snapshot: ConversationSnapshot) throws {
    if snapshot.chatId != chatId {
      rows = [:]
      chatId = snapshot.chatId
    }
    for row in snapshot.changed {
      if let kept = rows[row.key] { kept.snapshot = row } else { rows[row.key] = RowEntry(row) }
    }
    if snapshot.order != order {
      order = snapshot.order
      let kept = Set(order)
      rows = rows.filter { kept.contains($0.key) }
    }
    if loading != snapshot.loading { loading = snapshot.loading }
    if reactions != snapshot.reactions { reactions = snapshot.reactions }
    if chapters != snapshot.chapters { chapters = snapshot.chapters }
  }

  func formulas(pictures: [FormulaPicture]) throws {
    for picture in pictures {
      formulas[picture.id] = Formula(picture)
    }
    formulasLanded += 1
  }

  func detail(snapshot: DetailSnapshot) throws {
    if snapshot != detail { detail = snapshot }
  }
}

/// One row as Dart last sent it.
@Observable final class RowEntry {
  var snapshot: RowSnapshot
  init(_ snapshot: RowSnapshot) { self.snapshot = snapshot }
}

/// A typeset formula, decoded once.
struct Formula {
  let image: Image
  /// The same picture for a text view's attachment.
  let platform: PlatformImage
  let size: CGSize
  /// How far below its top the baseline sits.
  let baseline: CGFloat

  init?(_ picture: FormulaPicture) {
    guard let cg = decodedImage(picture.png.data) else { return nil }
    image = Image(decorative: cg, scale: picture.scale)
    size = CGSize(width: picture.width, height: picture.height)
    #if os(iOS)
      platform = UIImage(cgImage: cg, scale: picture.scale, orientation: .up)
    #else
      platform = NSImage(cgImage: cg, size: size)
    #endif
    baseline = picture.baseline
  }
}

/// The intents a view sends, none of them waited on.
extension TranscriptModel {
  func open(_ node: String) { say.open(node: node) { _ in } }
  func closeDetail() { say.closeDetail { _ in } }
  func detailAction(_ index: Int) { say.detailAction(index: Int64(index)) { _ in } }
  func link(_ href: String) { say.link(href: href) { _ in } }
  func act(_ row: String, _ action: MessageAction) { say.act(row: row, action: action) { _ in } }
  func edit(_ row: String, _ text: String) { say.edit(row: row, text: text) { _ in } }
  func react(_ row: String, _ emoji: String) { say.react(row: row, emoji: emoji) { _ in } }
  func reply(_ row: String, _ text: String) { say.reply(row: row, text: text) { _ in } }
  /// [text] parsed by the core, its formulas' pictures landed first; nil
  /// where the call failed.
  @MainActor func markdown(_ text: String, dark: Bool) async -> [TextBlockSnapshot]? {
    await entoli_glass.reply { documents.markdown(text: text, dark: dark, completion: $0) }
  }
  func documentLink(_ href: String) { documents.link(href: href) { _ in } }
  /// [code] as the core's grammar for the file [name] splits it.
  @MainActor func highlight(_ code: String, name: String) async -> [CodeTokenSnapshot]? {
    await entoli_glass.reply { documents.highlight(code: code, name: name, completion: $0) }
  }
  func openFile(_ row: String, block: Int, file: Int) {
    say.openFile(row: row, block: Int64(block), file: Int64(file)) { _ in }
  }
}
