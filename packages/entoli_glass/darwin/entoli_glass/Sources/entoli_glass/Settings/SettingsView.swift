import SwiftUI

/// The Settings scene's content, asked for before the engine has started:
/// the settings once the plugin has made its model, nothing until then.
public struct SettingsWindow: View {
  public init() {}

  public var body: some View {
    if let model = SettingsModel.shared {
      SettingsRoot(model: model)
    }
  }
}

/// The settings as the platform's own: the pages in a sidebar, each a form of
/// its sections, every row drawn from what Dart sent for it. On a Mac the
/// app's Settings window; on iOS a sheet over the app.
public struct SettingsRoot: View {
  @ObservedObject var model: SettingsModel

  public init(model: SettingsModel) { self.model = model }

  /// The listed pages in their groups, a group starting at each page that
  /// says it does.
  private var groups: [[SettingsPageData]] {
    model.listed.reduce(into: [[SettingsPageData]]()) { groups, page in
      if page.groupStart || groups.isEmpty { groups.append([]) }
      groups[groups.count - 1].append(page)
    }
  }

  public var body: some View {
    // The pages always beside the page, with no button to hide them.
    NavigationSplitView(columnVisibility: .constant(.all)) {
      List(selection: $model.page) {
        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
          Section {
            ForEach(group, id: \.key) { page in
              NavigationLink(value: page.key) {
                Label(page.title, systemImage: page.key.symbol)
              }
            }
          }
        }
      }
      .navigationTitle("Settings")
      .toolbar(removing: .sidebarToggle)
      #if os(macOS)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
      #endif
    } detail: {
      NavigationStack(path: $model.path) {
        if let key = model.page, let page = model.page(key) {
          SettingsPageView(model: model, page: page)
        }
      }
      .onChange(of: model.page) { model.path = NavigationPath() }
    }
    #if os(macOS)
      .frame(minWidth: 720, minHeight: 480)
    #else
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { model.presented = false }
        }
      }
    #endif
  }
}

/// One page: its sections as a grouped form.
struct SettingsPageView: View {
  @ObservedObject var model: SettingsModel
  let page: SettingsPageData

  var body: some View {
    Form {
      ForEach(page.sections.compactMap { $0 }, id: \.id) { section in
        Section {
          ForEach(section.rows.compactMap { $0 }.filter { $0.parent == nil }, id: \.id) {
            row in
            SettingRowView(model: model, row: row, section: section)
          }
        } header: {
          if !section.title.isEmpty { Text(section.title) }
        } footer: {
          if let detail = section.detail { Text(detail) }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(page.title)
    .navigationDestination(for: SettingsPageKey.self) { key in
      if let sub = model.page(key) { SettingsPageView(model: model, page: sub) }
    }
    .navigationDestination(for: OpenedText.self) { opened in
      TextPage(model: model, title: opened.title, opens: opened.opens)
    }
  }
}

/// One row, drawn by its kind, its hint where this frontend has that way.
struct SettingRowView: View {
  @ObservedObject var model: SettingsModel
  let row: SettingRowData
  let section: SettingsSectionData

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      content
      if let footnote = row.footnote, row.kind != .group {
        Text(footnote).font(.caption).foregroundStyle(.secondary)
      }
    }
    .disabled(!row.enabled)
  }

  @ViewBuilder private var content: some View {
    switch row.kind {
    case .toggle: ToggleRow(model: model, row: row)
    case .choice: ChoiceRow(model: model, row: row, accessory: accessory)
    case .slots: SlotsRow(model: model, row: row)
    case .range: RangeRow(model: model, row: row)
    case .keyValues: KeyValuesRow(model: model, row: row)
    case .action: ActionRow(model: model, row: row)
    case .group: GroupRow(model: model, row: row, section: section)
    case .number: NumberRow(model: model, row: row)
    case .modelPick: ModelPickRow(model: model, row: row)
    case .text: TextRow(model: model, row: row, accessory: accessory)
    case .notice: NoticeRow(row: row)
    case .collection:
      if row.hint == .triggers {
        TriggersView(model: model, row: row)
      } else {
        CollectionRow(model: model, row: row)
      }
    case .catalog: CatalogRow(model: model, row: row)
    case .info: InfoRow(model: model, row: row)
    case .subpage:
      if let page = row.page {
        NavigationLink(value: page) {
          LabeledContent(row.title, value: row.summary ?? "")
        }
      }
    case .pairing: PairingRow(model: model, row: row)
    case .setup: SetupRow(model: model, row: row)
    }
  }

  private var accessory: SettingRowData? { model.accessory(of: row, in: section) }
}

extension SettingsPageKey {
  /// The page's picture in the sidebar.
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .providers: "cloud"
    case .onDevice: "cpu"
    case .llms: "sparkles"
    case .images: "photo"
    case .memory: "brain"
    case .voice: "waveform"
    case .triggers: "alarm"
    case .agents: "person"
    case .skills: "puzzlepiece.extension"
    case .terminal: "terminal"
    case .agentBrowser: "safari"
    case .byteRepair: "checkmark.shield"
    case .sync: "arrow.triangle.2.circlepath"
    case .data: "archivebox"
    case .welcome: "hand.wave"
    case .shortcuts: "keyboard"
    case .about: "info.circle"
    case .syncRelay, .syncTurn: "network"
    case .onDeviceLlm: "slider.horizontal.3"
    }
  }
}

extension SettingIcon {
  var symbol: String {
    switch self {
    case .deleteForever: "trash"
    case .play: "play.circle"
    case .stop: "stop.circle"
    case .warning: "exclamationmark.triangle"
    case .shield: "checkmark.shield"
    case .appMark: "app"
    case .person: "person"
    case .code: "chevron.left.forwardslash.chevron.right"
    case .privacy: "hand.raised"
    case .licence: "scale.3d"
    case .add: "plus"
    case .download: "arrow.down.circle"
    case .upload: "square.and.arrow.up"
    case .notificationsOff: "bell.slash"
    case .alarmOff: "alarm"
    case .schedule: "calendar.badge.clock"
    case .countdown: "timer"
    case .files: "doc.text.magnifyingglass"
    case .online: "circle.fill"
    case .connecting, .offline: "circle"
    case .failed: "exclamationmark.circle"
    }
  }
}

extension SettingTone {
  var colour: Color {
    switch self {
    case .plain: .secondary
    case .good: .green
    case .warning: .orange
    }
  }
}

/// What an intent's answer says, shown: a confirm the action waits on, or a
/// notice once it ran. One per row, the view that asked holding it.
struct Asking: ViewModifier {
  @Binding var confirm: SettingConfirmData?
  @Binding var notice: SettingNoticeData?
  let agreed: () -> Void

  func body(content: Content) -> some View {
    content
      .alert(
        confirm?.title ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
        presenting: confirm
      ) { ask in
        if let label = ask.confirmLabel {
          Button(label, role: ask.destructive ? .destructive : nil) { agreed() }
          Button("Cancel", role: .cancel) {}
        } else {
          Button("OK", role: .cancel) {}
        }
      } message: { ask in
        Text(ask.message)
      }
      .alert(
        notice?.title ?? notice?.message ?? "",
        isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
        presenting: notice
      ) { _ in
        Button("OK", role: .cancel) {}
      } message: { notice in
        if notice.title != nil { Text(notice.message) }
      }
  }
}

extension View {
  func asking(
    _ confirm: Binding<SettingConfirmData?>,
    _ notice: Binding<SettingNoticeData?>,
    agreed: @escaping () -> Void
  ) -> some View {
    modifier(Asking(confirm: confirm, notice: notice, agreed: agreed))
  }
}
