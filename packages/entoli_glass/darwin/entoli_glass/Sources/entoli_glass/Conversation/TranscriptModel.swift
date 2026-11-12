import ImageIO
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
  private(set) var rows: [String: RowSnapshot] = [:]
  private(set) var running = false
  private(set) var flutterBottom: CGFloat = 0
  private(set) var reactions: [String] = []
  var detail = DetailSnapshot(
    present: false, title: "", statusError: false, sections: [], actions: [], mono: false,
    live: false)

  /// Each formula's picture by id, kept for the life of the engine: a
  /// formula is sent once.
  @ObservationIgnored private(set) var formulas: [Int64: Formula] = [:]

  /// Bumped as pictures land, so a row waiting on one redraws.
  private(set) var formulasLanded = 0

  let say: TranscriptIntents

  init(messenger: FlutterBinaryMessenger) {
    say = TranscriptIntents(binaryMessenger: messenger)
  }

  var present: Bool { chatId != nil && !order.isEmpty }
}

extension TranscriptModel: NativeTranscript {
  func conversation(snapshot: ConversationSnapshot) throws {
    if snapshot.chatId != chatId {
      rows = [:]
      chatId = snapshot.chatId
    }
    for row in snapshot.changed { rows[row.key] = row }
    if snapshot.order != order {
      order = snapshot.order
      let kept = Set(order)
      rows = rows.filter { kept.contains($0.key) }
    }
    if running != snapshot.running { running = snapshot.running }
    let bottom = CGFloat(snapshot.flutterBottom)
    if flutterBottom != bottom { flutterBottom = bottom }
    if reactions != snapshot.reactions { reactions = snapshot.reactions }
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

/// A typeset formula, decoded once.
struct Formula {
  let image: Image
  let size: CGSize
  /// How far below its top the baseline sits.
  let baseline: CGFloat

  init?(_ picture: FormulaPicture) {
    guard let image = Self.decode(picture.png.data, scale: picture.scale) else { return nil }
    self.image = image
    size = CGSize(width: picture.width, height: picture.height)
    baseline = picture.baseline
  }

  private static func decode(_ data: Data, scale: Double) -> Image? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    return Image(decorative: cg, scale: scale)
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
  func retry(_ row: String) { say.retry(row: row) { _ in } }
  func openPlan() { say.openPlan { _ in } }
  func openFile(_ row: String, block: Int, file: Int) {
    say.openFile(row: row, block: Int64(block), file: Int64(file)) { _ in }
  }
}
