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
      Group {
        #if os(macOS)
          PageStack(model: model)
        #else
          NavigationStack(path: $model.path) {
            if let key = model.page, let page = model.page(key) {
              SettingsPageView(model: model, page: page)
                .navigationDestination(for: SettingsRoute.self) { route in
                  SettingsDestination(model: model, route: route)
                }
            }
          }
        #endif
      }
      .onChange(of: model.page) {
        model.path = []
        model.ahead = []
      }
    }
    #if os(macOS)
      .frame(minWidth: 720, minHeight: 480)
      .background(UnifiedToolbar())
    #else
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { model.presented = false }
        }
      }
    #endif
    // Dart builds the pages only while they are on screen.
    .onAppear { model.say.shown(on: true, completion: ignore) }
    .onDisappear { model.say.shown(on: false, completion: ignore) }
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
            SettingRowView(model: model, row: row)
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
  }
}

/// One row, drawn by its kind, its hint where this frontend has that way.
/// Redrawn with the page that holds it, as a snapshot changes its row.
struct SettingRowView: View {
  let model: SettingsModel
  let row: SettingRowData

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
    case .action:
      if row.hint == .botAvatars {
        // This frontend's own page of them, rather than Flutter's.
        PushRow(model: model, to: .avatars(OpenedAvatars(agent: nil, row: row.id, index: -1))) {
          Label(row.title, systemImage: "face.smiling")
        }
        .foregroundStyle(Color.accentColor)
      } else {
        ActionRow(model: model, row: row)
      }
    case .group: GroupRow(model: model, row: row)
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
        PushRow(model: model, to: .page(page)) {
          LabeledContent(row.title, value: row.summary ?? "")
        }
      }
    case .pairing: PairingRow(model: model, row: row)
    case .setup: SetupRow(model: model, row: row)
    }
  }

  private var accessory: SettingRowData? { model.accessory(of: row) }
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
    case .cloud: "cloud"
    case .computer: "desktopcomputer"
    case .terminal: "terminal"
    case .tune: "slider.horizontal.3"
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
      // A notice carrying a link has it put on the clipboard as it is said.
      .onChange(of: notice?.copy) { _, copy in
        guard let copy else { return }
        #if os(macOS)
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(copy, forType: .string)
        #else
          UIPasteboard.general.string = copy
        #endif
      }
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

#if os(macOS)
  /// The detail pane's pages, drawn here rather than by a NavigationStack: in
  /// a split view's detail column a Mac's stack shows a pushed page with no
  /// animation (macOS 27, a plain NavigationLink included), though it
  /// animates a pop. Only the top page is drawn, pushed in from the side it
  /// comes from.
  private struct PageStack: View {
    @ObservedObject var model: SettingsModel

    private struct Place: Hashable {
      let page: SettingsPageKey?
      let depth: Int
    }

    var body: some View {
      ZStack {
        Group {
          if let route = model.path.last {
            SettingsDestination(model: model, route: route)
          } else if let key = model.page, let page = model.page(key) {
            SettingsPageView(model: model, page: page)
          }
        }
        .id(Place(page: model.page, depth: model.path.count))
        .transition(.push(from: model.forwards ? .trailing : .leading))
      }
      .toolbar {
        ToolbarItemGroup(placement: .navigation) { PageArrows(model: model) }
      }
    }
  }

  /// Back and Forward through the pages pushed in this pane.
  private struct PageArrows: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
      Button {
        model.back()
      } label: {
        Label("Back", systemImage: "chevron.left")
      }
      .disabled(model.path.isEmpty)
      .keyboardShortcut("[", modifiers: .command)
      .help("Back")
      Button {
        model.forward()
      } label: {
        Label("Forward", systemImage: "chevron.right")
      }
      .disabled(model.ahead.isEmpty)
      .keyboardShortcut("]", modifiers: .command)
      .help("Forward")
    }
  }
#endif

#if os(macOS)
  /// The Settings window's toolbar as the main window's: one row, the title
  /// in it beside Back and Forward. A Settings scene's window is AppKit's
  /// preference style — the title on a row of its own over the toolbar's
  /// items, centred — and SwiftUI's scene modifier does not reach it.
  private struct UnifiedToolbar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Hook() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Hook: NSView {
      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.toolbarStyle = .unified
      }
    }
  }
#endif

/// The page a pushed [route] opens.
private struct SettingsDestination: View {
  @ObservedObject var model: SettingsModel
  let route: SettingsRoute

  var body: some View {
    Group {
      switch route {
      case .page(let key):
        if let sub = model.page(key) { SettingsPageView(model: model, page: sub) }
      case .text(let opened):
        TextPage(model: model, title: opened.title, opens: opened.opens)
      case .avatars(let opened):
        BotAvatarsPage(model: model, opened: opened)
      case .models(let opened):
        if let row = model.row(opened.row) { ModelList(model: model, row: row) }
      }
    }
  }
}
