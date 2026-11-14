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
  @Bindable var model: SettingsModel

  public init(model: SettingsModel) { self.model = model }

  /// The listed pages in their groups, a group starting at each page that
  /// says it does.
  private var groups: [[SettingsPageData]] {
    model.listed.reduce(into: [[SettingsPageData]]()) { groups, page in
      if page.groupStart || groups.isEmpty { groups.append([]) }
      groups[groups.count - 1].append(page)
    }
  }

  /// The sidebar's selection: a page, or a search result, which opens its
  /// page at its row. A selection rather than a button, since a phone's
  /// collapsed split view goes to the detail only for a selection.
  private var picked: Binding<SidebarPick?> {
    Binding(
      get: { model.page.map(SidebarPick.page) },
      set: { pick in
        switch pick {
        case .page(let key)?: model.page = key
        case .hit(let key, let row)?: model.open(key, at: row)
        case nil: model.page = nil
        }
      })
  }

  public var body: some View {
    // The pages always beside the page, with no button to hide them.
    NavigationSplitView(columnVisibility: .constant(.all)) {
      List(selection: picked) {
        if model.query.isEmpty {
          ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
            Section {
              ForEach(group, id: \.key) { page in
                NavigationLink(value: SidebarPick.page(page.key)) {
                  Label {
                    Text(page.title)
                  } icon: {
                    PageIcon(key: page.key)
                  }
                }
              }
            }
          }
        } else {
          SearchResults(model: model)
        }
      }
      .disabled(model.held)
      .searchable(text: $model.query, placement: .sidebar, prompt: "Search settings")
      .overlay {
        if !model.query.isEmpty && model.found.isEmpty {
          ContentUnavailableView.search(text: model.query)
        }
      }
      .navigationTitle("Settings")
      .toolbar(removing: .sidebarToggle)
      #if os(iOS)
        // On the list rather than the split view, whose own toolbar a
        // phone's collapsed one does not show.
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            DoneButton { model.presented = false }.disabled(model.held)
          }
        }
      #endif
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
    }
    #if os(macOS)
      .frame(minWidth: 720, minHeight: 480)
      .background(UnifiedToolbar())
    #endif
    // Dart builds the pages only while they are on screen.
    .onAppear { model.say.shown(on: true, pages: model.drawn, completion: ignore) }
    .onChange(of: model.drawn) { model.say.shown(on: true, pages: model.drawn, completion: ignore) }
    .onDisappear { model.say.shown(on: false, pages: [], completion: ignore) }
  }
}

/// One page: its sections as a grouped form. A row a search opened is
/// scrolled to and lit for a moment.
struct SettingsPageView: View {
  var model: SettingsModel
  let page: SettingsPageData

  @State private var lit: String?

  var body: some View {
    ScrollViewReader { proxy in
      Form {
        ForEach(page.sections.compactMap { $0 }, id: \.id) { section in
          Section {
            ForEach(section.rows.compactMap { $0 }.filter { $0.parent == nil }, id: \.id) {
              row in
              SettingRowView(model: model, row: row)
                .id(row.id)
                .listRowBackground(lit == row.id ? Color.accentColor.opacity(0.18) : nil)
            }
          } header: {
            if !section.title.isEmpty { Text(section.title) }
          } footer: {
            let words = [section.detail, section.footnote].compactMap { $0 }
            if !words.isEmpty { Text(words.joined(separator: "\n\n")) }
          }
        }
      }
      .formStyle(.grouped)
      .task(id: model.revealed) { await reveal(proxy) }
      .task(id: model.arriving) { await arrive() }
    }
    .navigationTitle(page.title)
    // Hiding it takes the edge swipe back with it.
    .navigationBarBackButtonHidden(page.held)
  }

  /// The sub-page a search opened, pushed over this page once it is up.
  private func arrive() async {
    guard let key = model.arriving, model.page == page.key, model.path.isEmpty else { return }
    model.arriving = nil
    try? await Task.sleep(for: .milliseconds(350))
    model.push(.page(key))
  }

  /// The row a search opened, if it is on this page: brought into sight,
  /// then lit and let fade.
  private func reveal(_ proxy: ScrollViewProxy) async {
    guard let id = model.revealed, model.home(of: id) == page.key else { return }
    model.revealed = nil
    // After the push lands, or the scroll is lost to it.
    try? await Task.sleep(for: .milliseconds(350))
    withAnimation(.smooth) { proxy.scrollTo(id, anchor: .center) }
    withAnimation(.easeOut(duration: 0.2)) { lit = id }
    try? await Task.sleep(for: .seconds(1.2))
    withAnimation(.easeIn(duration: 0.6)) { lit = nil }
  }
}

/// What a search found: per page, the page itself where its title matched
/// and each row that did, under the page's name.
private struct SearchResults: View {
  let model: SettingsModel

  var body: some View {
    ForEach(model.found) { hit in
      Section(hit.page.title) {
        if hit.titled {
          result(hit.page.title, page: hit.page.key, row: nil)
        }
        ForEach(hit.rows, id: \.id) { row in
          result(row.title, detail: row.detail, page: hit.page.key, row: row.id)
        }
      }
    }
  }

  private func result(
    _ title: String, detail: String? = nil, page: SettingsPageKey, row: String?
  ) -> some View {
    NavigationLink(value: SidebarPick.hit(page, row: row)) {
      Label {
        Text(title)
        if let detail { Text(detail).lineLimit(2) }
      } icon: {
        PageIcon(key: page)
      }
    }
  }
}

/// What the settings sidebar can have picked.
private enum SidebarPick: Hashable {
  case page(SettingsPageKey)
  case hit(SettingsPageKey, row: String?)
}

/// A page's picture as Settings draws its own: a white symbol on a tile in
/// the page's colour.
struct PageIcon: View {
  let key: SettingsPageKey

  #if os(macOS)
    private static let side: CGFloat = 20
    private static let glyph: CGFloat = 11
  #else
    private static let side: CGFloat = 29
    private static let glyph: CGFloat = 15
  #endif

  var body: some View {
    Image(systemName: key.symbol)
      .font(.system(size: Self.glyph, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: Self.side, height: Self.side)
      .background(
        key.tint.gradient,
        in: RoundedRectangle(cornerRadius: Self.side * 0.23, style: .continuous)
      )
      .accessibilityHidden(true)
  }
}

/// The sheet's way out: the system's close where it has one, Done before.
private struct DoneButton: View {
  let action: () -> Void

  var body: some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      Button(role: .close, action: action)
    } else {
      Button("Done", action: action)
    }
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
    case .document: DocumentRow(model: model, row: row).frame(minHeight: 360)
    case .web: WebRow(model: model, row: row).frame(minHeight: 360)
    case .prompt: PromptRow(model: model, row: row)
    }
  }

  private var accessory: SettingRowData? { model.accessory(of: row) }
}

extension SettingsPageKey {
  /// The page's symbol on its tile.
  var symbol: String {
    switch self {
    case .general: "gearshape.fill"
    case .providers: "cloud.fill"
    case .onDevice: "cpu.fill"
    case .llms: "sparkles"
    case .images: "photo.fill"
    case .memory: "brain"
    case .voice: "waveform"
    case .triggers: "alarm.fill"
    case .agents: "person.fill"
    case .skills: "puzzlepiece.extension.fill"
    case .terminal: "terminal.fill"
    case .agentBrowser: "safari.fill"
    case .byteRepair: "checkmark.shield.fill"
    case .sync: "arrow.triangle.2.circlepath"
    case .data: "archivebox.fill"
    case .welcome: "hand.wave.fill"
    case .shortcuts: "keyboard.fill"
    case .about: "info"
    case .syncRelay, .syncTurn: "network"
    case .onDeviceLlm: "slider.horizontal.3"
    case .app: "doc.fill"
    }
  }

  /// The tile's colour, as Settings colours its own pages: kin pages in kin
  /// colours, the app's own in grey.
  var tint: Color {
    switch self {
    case .general, .shortcuts, .about: .gray
    case .providers, .agentBrowser, .syncRelay, .syncTurn: .blue
    case .onDevice, .onDeviceLlm: .indigo
    case .llms: .purple
    case .images: .orange
    case .memory: .pink
    case .voice: .red
    case .triggers: .orange
    case .agents: .teal
    case .skills: .mint
    case .terminal: Color(white: 0.2)
    case .byteRepair: .green
    case .sync: .cyan
    case .data: .brown
    case .welcome: .yellow
    case .app: .gray
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
    case .taskDone: "checkmark.circle.fill"
    case .taskActive: "circle.dotted.circle"
    case .taskPending: "circle"
    case .folder: "folder"
    case .file: "doc"
    case .chat: "bubble.left"
    case .memory: "brain"
    case .link: "link"
    case .skill: "puzzlepiece.extension"
    case .agent: "person.crop.circle"
    case .edit: "pencil"
    case .globe: "globe"
    case .check: "checkmark"
    case .info: "info.circle"
    case .star: "star"
    case .copy: "doc.on.doc"
    case .reveal: "arrow.up.forward.app"
    case .newFolder: "folder.badge.plus"
    case .restart: "arrow.counterclockwise"
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
        if let copy { copyToPasteboard(copy) }
      }
      .alert(
        confirm?.title ?? "", isPresented: .present($confirm),
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
        isPresented: .present($notice),
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
  /// animates a pop. Every page of the stack is drawn, each over the one
  /// beneath, as a Mac app's pages stack: a page pushed slides in from the
  /// trailing edge over the one shown, which stays where it is, and slides
  /// back out the same way.
  private struct PageStack: View {
    var model: SettingsModel

    /// One page of the stack: the page picked at the bottom, and each one
    /// pushed over it. The picked page is in every level, so picking another
    /// is a new stack rather than a push.
    private struct Level: Hashable {
      let root: SettingsPageKey?
      let depth: Int
      let route: SettingsRoute?
    }

    private var levels: [Level] {
      [Level(root: model.page, depth: 0, route: nil)]
        + model.path.enumerated().map {
          Level(root: model.page, depth: $0.offset + 1, route: $0.element)
        }
    }

    var body: some View {
      let top = model.path.count
      ZStack {
        ForEach(levels, id: \.self) { level in
          page(level)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Opaque, or the page beneath shows through a form's gaps.
            .background(.background)
            .zIndex(Double(level.depth))
            .allowsHitTesting(level.depth == top)
            .accessibilityHidden(level.depth != top)
            .transition(level.depth == 0 ? .identity : .move(edge: .trailing))
        }
      }
      .clipped()
      .toolbar {
        ToolbarItemGroup(placement: .navigation) { PageArrows(model: model) }
      }
    }

    @ViewBuilder private func page(_ level: Level) -> some View {
      if let route = level.route {
        SettingsDestination(model: model, route: route)
      } else if let key = level.root, let page = model.page(key) {
        SettingsPageView(model: model, page: page)
      }
    }
  }

  /// Back and Forward through the pages pushed in this pane.
  private struct PageArrows: View {
    var model: SettingsModel

    var body: some View {
      Button {
        model.back()
      } label: {
        Label("Back", systemImage: "chevron.left")
      }
      .disabled(model.path.isEmpty || model.held)
      .keyboardShortcut("[", modifiers: .command)
      .help("Back")
      Button {
        model.forward()
      } label: {
        Label("Forward", systemImage: "chevron.right")
      }
      .disabled(model.ahead.isEmpty || model.held)
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
struct SettingsDestination: View {
  var model: SettingsModel
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
      case .device(let id):
        PairedDevicePage(model: model, id: id)
      case .app(let address):
        if let pages = AppPagesModel.shared, let page = pages.page(address) {
          AppPageView(model: pages, page: page)
        }
      }
    }
  }
}
