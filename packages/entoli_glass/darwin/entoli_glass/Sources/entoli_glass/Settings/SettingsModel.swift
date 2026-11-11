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

  /// What is pushed over the page: subpages and pages of text.
  @Published var path = NavigationPath()

  /// Whether the settings are up, where they are a sheet: iOS.
  @Published var presented = false

  let say: SettingsIntents

  init(messenger: FlutterBinaryMessenger) {
    say = SettingsIntents(binaryMessenger: messenger)
  }

  func settings(snapshot: SettingsSnapshot) throws {
    pages = snapshot.pages.compactMap { $0 }
  }

  func show(page: SettingsPageKey?) throws {
    #if os(macOS)
      if let page { self.page = page }
      // The app's Settings scene: AppKit's own action opens its window.
      NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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

  func models(_ id: String) async -> [ModelEntry] {
    await withCheckedContinuation { done in
      say.models(id: id) {
        let entries = ((try? $0.get()) ?? []).compactMap(ModelEntry.init)
        done.resume(returning: entries)
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
struct ModelEntry: Identifiable, Hashable {
  let providerId: String?
  let modelId: String?
  let label: String
  let section: String

  var id: String { "\(providerId ?? "")/\(modelId ?? "")" }

  init?(_ wire: String) {
    let parts = wire.components(separatedBy: "\u{0}")
    guard parts.count == 4 else { return nil }
    providerId = parts[0].isEmpty ? nil : parts[0]
    modelId = parts[1].isEmpty ? nil : parts[1]
    label = parts[2]
    section = parts[3]
  }
}

/// A no-op answer for the intents that wait on nothing.
func ignore(_: Result<Void, PigeonError>) {}
