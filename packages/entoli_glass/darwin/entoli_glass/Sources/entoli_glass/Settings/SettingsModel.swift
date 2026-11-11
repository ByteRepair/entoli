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
public final class SettingsModel: ObservableObject, NativeSettings {
  /// The one, made as the plugin registers.
  public static var shared: SettingsModel?

  @Published var pages: [SettingsPageData] = []

  /// The page asked for last, which the settings open at; none on a phone
  /// opened plainly, which starts at the list of pages.
  @Published var page: SettingsPageKey? = .general

  /// What is pushed over the page, and what Back left behind for Forward.
  @Published var path: [SettingsRoute] = []
  @Published var ahead: [SettingsRoute] = []

  /// Whether the settings are up, where they are a sheet: iOS.
  @Published var presented = false

  let say: SettingsIntents

  init(messenger: FlutterBinaryMessenger) {
    say = SettingsIntents(binaryMessenger: messenger)
  }

  func settings(snapshot: SettingsSnapshot) throws {
    pages = snapshot.pages.compactMap { $0 }
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

  /// The pages offered among the others, rather than opened from a row.
  var listed: [SettingsPageData] { pages.filter(\.listed) }

  func page(_ key: SettingsPageKey) -> SettingsPageData? {
    pages.first { $0.key == key }
  }

  /// The row [id] names, on whichever page it is.
  func row(_ id: String) -> SettingRowData? {
    for page in pages {
      for section in page.sections.compactMap({ $0 }) {
        if let row = section.rows.compactMap({ $0 }).first(where: { $0.id == id }) { return row }
      }
    }
    return nil
  }

  /// Pushes [route]'s page over the one shown, clearing Forward. Animated:
  /// a Mac's stack slides a page in only for a change made in an animation.
  func push(_ route: SettingsRoute) {
    ahead = []
    withAnimation(.smooth(duration: 0.3)) { path.append(route) }
  }

  /// What [route]'s page is called, for its header.
  func title(of route: SettingsRoute) -> String {
    switch route {
    case .page(let key): page(key)?.title ?? ""
    case .text(let opened): opened.title
    case .avatars(let opened): opened.agent == nil ? "Bot Avatars" : "Bot Avatar"
    case .models(let opened): row(opened.row)?.title ?? ""
    }
  }

  /// Back one page, kept for Forward.
  func back() {
    guard let last = path.last else { return }
    ahead.append(last)
    withAnimation(.smooth(duration: 0.3)) { _ = path.removeLast() }
  }

  /// The page Back left.
  func forward() {
    guard let next = ahead.popLast() else { return }
    withAnimation(.smooth(duration: 0.3)) { path.append(next) }
  }

  /// [row]'s own rows: a group's children, and an accessory drawn at its end.
  func children(of row: SettingRowData, in section: SettingsSectionData) -> [SettingRowData] {
    section.rows.compactMap { $0 }.filter { $0.parent == row.id && !$0.accessory }
  }

  func accessory(of row: SettingRowData, in section: SettingsSectionData) -> SettingRowData? {
    section.rows.compactMap { $0 }.first { $0.parent == row.id && $0.accessory }
  }
}

/// What an intent answers, on the main thread: what the view shows next.
extension SettingsModel {
  func ask(_ id: String) async -> SettingConfirmData? {
    await withCheckedContinuation { done in
      say.ask(id: id) { done.resume(returning: (try? $0.get()) ?? nil) }
    }
  }

  func run(_ id: String) async -> SettingNoticeData? {
    await withCheckedContinuation { done in
      say.run(id: id) { done.resume(returning: (try? $0.get()) ?? nil) }
    }
  }

  func itemAction(_ id: String, _ index: Int, _ action: String) async -> SettingNoticeData? {
    await withCheckedContinuation { done in
      say.itemAction(id: id, index: Int64(index), action: action) {
        done.resume(returning: (try? $0.get()) ?? nil)
      }
    }
  }

  func form(_ id: String, _ index: Int?, _ answers: [String?: String?]?) async
    -> SettingFormData?
  {
    await withCheckedContinuation { done in
      say.form(id: id, index: index.map(Int64.init), answers: answers) {
        done.resume(returning: try? $0.get())
      }
    }
  }

  func submit(_ id: String, _ index: Int?, _ answers: [String?: String?]) async
    -> SettingNoticeData?
  {
    await withCheckedContinuation { done in
      say.submitForm(id: id, index: index.map(Int64.init), answers: answers) {
        done.resume(returning: (try? $0.get()) ?? nil)
      }
    }
  }

  func models(_ id: String) async -> ModelPickerData? {
    await withCheckedContinuation { done in
      say.models(id: id) { done.resume(returning: try? $0.get()) }
    }
  }

  func modelForm(
    _ id: String, _ providerId: String?, _ modelId: String?, _ answers: [String?: String?]?
  ) async -> SettingFormData? {
    await withCheckedContinuation { done in
      say.modelForm(id: id, providerId: providerId, modelId: modelId, answers: answers) {
        done.resume(returning: try? $0.get())
      }
    }
  }

  func submitModelForm(
    _ id: String, _ providerId: String?, _ modelId: String?, _ answers: [String?: String?]
  ) async -> SettingNoticeData? {
    await withCheckedContinuation { done in
      say.submitModelForm(id: id, providerId: providerId, modelId: modelId, answers: answers) {
        done.resume(returning: (try? $0.get()) ?? nil)
      }
    }
  }

  func text(of opens: String) async -> String {
    await withCheckedContinuation { done in
      say.page(opens: opens) { done.resume(returning: (try? $0.get()) ?? "") }
    }
  }

  func pairWith(_ id: String, _ code: String) async -> String? {
    await withCheckedContinuation { done in
      say.pairWith(id: id, code: code) { done.resume(returning: (try? $0.get()) ?? nil) }
    }
  }

  func invite(_ id: String) async -> String {
    await withCheckedContinuation { done in
      say.createInvite(id: id) { done.resume(returning: (try? $0.get()) ?? "") }
    }
  }
}

/// One entry of a model picker: the pair it stores, what it is called, and
/// the provider it is listed under.
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

/// A page pushed over a settings page.
enum SettingsRoute: Hashable {
  case page(SettingsPageKey)
  case text(OpenedText)
  case avatars(OpenedAvatars)
  case models(OpenedModels)
}
