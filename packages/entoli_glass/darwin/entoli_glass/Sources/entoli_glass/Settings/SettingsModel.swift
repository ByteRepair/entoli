import SwiftUI

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// The settings as Dart last sent them, every page built from the schema;
/// and the way back, [say], an intent per thing a row can have done to it.
/// Holds nothing of its own: a snapshot replaces what was there, and a change
/// is an intent Dart answers with the next snapshot. The [NativeSettings] end
/// of `pigeons/settings.dart`.
@Observable public final class SettingsModel: NativeSettings {
  /// The one, made as the plugin registers.
  public static var shared: SettingsModel?

  var pages: [SettingsPageData] = []

  /// The page asked for last, which the settings open at; none on a phone
  /// opened plainly, which starts at the list of pages. Another page starts
  /// with nothing pushed over it.
  var page: SettingsPageKey? = .general {
    didSet {
      guard page != oldValue else { return }
      path = []
      ahead = []
    }
  }

  /// What the settings are searched for. While it holds a word every page
  /// is built, so a row on a page nobody has opened can be found.
  var query = "" { didSet { search() } }

  /// What [query] finds, worked out as the query or the pages change.
  private(set) var found: [SearchHit] = []

  /// The row a search result opened: its page scrolls to it and lights it
  /// once.
  var revealed: String?

  /// A sub-page a search result opened, pushed once the page that opens it
  /// is on screen: a phone's collapsed split view resets the detail's stack
  /// as it goes to it, dropping a path set in the same moment.
  var arriving: SettingsPageKey?

  /// What is pushed over the page, and what Back left behind for Forward.
  var path: [SettingsRoute] = []
  var ahead: [SettingsRoute] = []

  /// Whether the settings are up, where they are a sheet: iOS.
  var presented = false

  let say: SettingsIntents

  init(messenger: FlutterBinaryMessenger) {
    say = SettingsIntents(binaryMessenger: messenger)
  }

  /// Every row by its id, the page it is on, and each row's own beneath
  /// it, looked up once per snapshot rather than by every row as it draws.
  @ObservationIgnored private var rows: [String: SettingRowData] = [:]
  @ObservationIgnored private var homes: [String: SettingsPageKey] = [:]
  @ObservationIgnored private var parts: [String: [SettingRowData]] = [:]
  @ObservationIgnored private var accessories: [String: SettingRowData] = [:]

  func settings(snapshot: SettingsSnapshot) throws {
    let next = snapshot.pages.compactMap { $0 }
    rows = [:]
    homes = [:]
    parts = [:]
    accessories = [:]
    for page in next {
      for row in page.rows {
        rows[row.id] = row
        homes[row.id] = page.key
        guard let parent = row.parent else { continue }
        if row.accessory {
          accessories[parent] = row
        } else {
          parts[parent, default: []].append(row)
        }
      }
    }
    pages = next
    search()
  }

  #if os(macOS)
    /// SwiftUI's way to the Settings scene, which only a view can read: set
    /// by `SettingsWindowOpener` in the app's window. AppKit's own
    /// `showSettingsWindow:` action opens nothing from macOS 14.
    static var openWindow: (() -> Void)?
  #endif

  func show(page: SettingsPageKey?) throws {
    #if os(macOS)
      if let page { self.page = page }
      Self.openWindow?()
      NSApp.activate()
    #else
      self.page = page
      presented = true
    #endif
  }

  /// Out of the way of a page the Flutter app opens over the conversation:
  /// the sheet down on iOS, the Settings window closed on a Mac.
  func stepAside() {
    #if os(macOS)
      NSApp.keyWindow?.close()
    #else
      presented = false
    #endif
  }

  /// The pages drawn: the one picked and every one pushed over it, or all of
  /// them while a search is under way.
  var drawn: [SettingsPageKey] {
    if !SearchWords(query).isEmpty { return pages.map(\.key) }
    return [page].compactMap { $0 }
      + path.compactMap {
        if case .page(let key) = $0 { key } else { nil }
      }
  }

  /// The pages offered among the others, rather than opened from a row.
  var listed: [SettingsPageData] { pages.filter { $0.openedFrom == nil } }

  func page(_ key: SettingsPageKey) -> SettingsPageData? {
    pages.first { $0.key == key }
  }

  /// The row [id] names, on whichever page it is.
  func row(_ id: String) -> SettingRowData? { rows[id] }

  /// Pushes [route]'s page over the one shown, clearing Forward.
  func push(_ route: SettingsRoute) {
    move {
      ahead = []
      path.append(route)
    }
  }

  /// [change] to the stack, animated even from inside a form row, whose tap
  /// otherwise carries a transaction with animations turned off.
  private func move(_ change: () -> Void) {
    var transaction = Transaction(animation: .smooth(duration: 0.3))
    transaction.disablesAnimations = false
    withTransaction(transaction, change)
  }

  /// Back one page, kept for Forward.
  func back() {
    guard let last = path.last else { return }
    ahead.append(last)
    move { _ = path.removeLast() }
  }

  /// The page Back left.
  func forward() {
    guard let next = ahead.popLast() else { return }
    move { path.append(next) }
  }

  /// The paired device whose page is up, as Dart last sent it: none yet,
  /// or with why its record could not be read.
  struct ShownDevice {
    let id: String
    let record: PairedDeviceData?
    let readError: String?
  }

  private(set) var device: ShownDevice?

  /// The open form's program account, as Dart last sent it; none until it
  /// has asked the program.
  private(set) var cliAccount: CliAccountData?

  /// A device page asked for and not yet pushed: it waits for its record,
  /// or it would slide in empty and fill once it had stopped.
  @ObservationIgnored private var opening: String?

  func openDevice(id: String) throws {
    device = nil
    opening = id
    say.deviceShown(id: id, completion: ignore)
  }

  func device(id: String, device: PairedDeviceData?, readError: String?) throws {
    self.device = ShownDevice(id: id, record: device, readError: readError)
    if opening == id {
      opening = nil
      push(.device(id))
    }
  }

  /// Fills [found]: per page, in the pages' order, whether its title
  /// matched and the rows whose title or description did. A row inside a
  /// group is found as itself, and opened at the group.
  private func search() {
    let words = SearchWords(query)
    guard !words.isEmpty else {
      if !found.isEmpty { found = [] }
      return
    }
    found = pages.compactMap { page in
      let rows = page.rows.filter {
        !$0.accessory && words.found(in: "\($0.title) \($0.detail ?? "")".lowercased())
      }
      // A page with a row of its own name is found once, at the row.
      let titled =
        words.found(in: page.title.lowercased()) && !rows.contains { $0.title == page.title }
      return titled || !rows.isEmpty ? SearchHit(page: page, titled: titled, rows: rows) : nil
    }
  }

  /// Opens [key] where it lives — a listed page picked, a sub-page pushed
  /// over the page that opens it — and scrolls to [row] there.
  func open(_ key: SettingsPageKey, at row: String?) {
    let opener = page(key)?.openedFrom
    page = opener ?? key
    arriving = opener.map { _ in key }
    revealed = row.map { rows[$0]?.parent ?? $0 }
  }

  /// The page [row] is on.
  func home(of row: String) -> SettingsPageKey? { homes[row] }

  /// [row]'s own rows: a group's children, and an accessory drawn at its end.
  func children(of row: SettingRowData) -> [SettingRowData] { parts[row.id] ?? [] }

  func accessory(of row: SettingRowData) -> SettingRowData? { accessories[row.id] }
}

/// What an intent answers, on the main thread: what the view shows next.
extension SettingsModel {
  func ask(_ id: String) async -> SettingConfirmData? {
    await reply(or: nil) { say.ask(id: id, completion: $0) }
  }

  func run(_ id: String) async -> SettingNoticeData? {
    await reply(or: nil) { say.run(id: id, completion: $0) }
  }

  func itemAction(_ id: String, _ index: Int, _ action: String) async -> SettingNoticeData? {
    await reply(or: nil) {
      say.itemAction(id: id, index: Int64(index), action: action, completion: $0)
    }
  }

  func form(_ id: String, _ index: Int?, _ answers: [String?: String?]?) async
    -> SettingFormData?
  {
    await reply { say.form(id: id, index: index.map(Int64.init), answers: answers, completion: $0) }
  }

  func submit(_ id: String, _ index: Int?, _ answers: [String?: String?]) async
    -> FormSaveData?
  {
    await reply(or: nil) {
      say.submitForm(id: id, index: index.map(Int64.init), answers: answers, completion: $0)
    }
  }

  func models(_ id: String) async -> ModelPickerData? {
    await reply { say.models(id: id, completion: $0) }
  }

  func modelForm(
    _ id: String, _ providerId: String?, _ modelId: String?, _ answers: [String?: String?]?
  ) async -> SettingFormData? {
    await reply {
      say.modelForm(
        id: id, providerId: providerId, modelId: modelId, answers: answers, completion: $0)
    }
  }

  func submitModelForm(
    _ id: String, _ providerId: String?, _ modelId: String?, _ answers: [String?: String?]
  ) async -> FormSaveData? {
    await reply(or: nil) {
      say.submitModelForm(
        id: id, providerId: providerId, modelId: modelId, answers: answers, completion: $0)
    }
  }

  func cliAccount(account: CliAccountData) throws { cliAccount = account }

  /// Watches the account of the program form [id]'s sign-in names.
  func openCliAccount(_ id: String, _ index: Int?, _ answers: [String?: String?]) {
    cliAccount = nil
    say.openCliAccount(id: id, index: index.map(Int64.init), answers: answers, completion: ignore)
  }

  func cliAccountOp(_ op: CliAccountOp) {
    say.cliAccountOp(op: op, completion: ignore)
  }

  func closeCliAccount() {
    cliAccount = nil
    say.closeCliAccount(completion: ignore)
  }

  func text(of opens: TextPageData) async -> String {
    await reply(or: "") { say.page(opens: opens, completion: $0) }
  }

  func deviceAction(_ id: String, _ op: DeviceOp, name: String? = nil) async
    -> SettingNoticeData?
  {
    await reply(or: nil) { say.deviceAction(id: id, op: op, name: name, completion: $0) }
  }

  func pairWith(_ id: String, _ code: String) async -> String? {
    await reply(or: nil) { say.pairWith(id: id, code: code, completion: $0) }
  }

  func invite(_ id: String) async -> String {
    await reply(or: "") { say.createInvite(id: id, completion: $0) }
  }
}

/// What an intent [call] answers, or nil where it failed.
func reply<T>(_ call: (@escaping (Result<T, PigeonError>) -> Void) -> Void) async -> T? {
  await withCheckedContinuation { done in call { done.resume(returning: try? $0.get()) } }
}

/// What an intent [call] answers, or [fallback] where it failed.
func reply<T>(or fallback: T, _ call: (@escaping (Result<T, PigeonError>) -> Void) -> Void)
  async -> T
{
  await reply(call) ?? fallback
}

/// A no-op answer for the intents that wait on nothing.
func ignore(_: Result<Void, PigeonError>) {}

#if os(macOS)
  /// Hands SwiftUI's `openSettings` to the model, for a page Dart asks to
  /// open — About from the menu, a setup row — with the window closed. Sits
  /// in the app's main window, the one view that is always there.
  public struct SettingsWindowOpener: View {
    @Environment(\.openSettings) private var openSettings

    public init() {}

    public var body: some View {
      Color.clear
        .frame(width: 0, height: 0)
        .onAppear { SettingsModel.openWindow = { openSettings() } }
    }
  }
#endif

/// One page of what a search found.
struct SearchHit: Identifiable {
  let page: SettingsPageData
  /// Whether the page's own title matched.
  let titled: Bool
  let rows: [SettingRowData]

  var id: SettingsPageKey { page.key }
}

extension SettingsPageData {
  /// Every row on the page, a group's own among them.
  var rows: [SettingRowData] { sections.compactMap { $0 }.flatMap { $0.rows.compactMap { $0 } } }
}

/// A page pushed over a settings page.
enum SettingsRoute: Hashable {
  case page(SettingsPageKey)
  case text(OpenedText)
  case avatars(OpenedAvatars)
  case models(OpenedModels)
  /// A paired device's page, by its id.
  case device(String)
}
