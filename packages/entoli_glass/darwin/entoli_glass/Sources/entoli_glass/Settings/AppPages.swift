import SwiftUI

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// The app's pages open over the window, as Dart last sent them: a chat's
/// settings, the plan, the workspace, each a settings page of rows. They
/// are drawn by the settings' own row views through [rows], a settings model
/// of their own whose path is the stack: the first page at the root, each
/// one Dart opens over it pushed, and what a row pushes in between.
@Observable final class AppPagesModel {
  static var shared: AppPagesModel?

  let rows: SettingsModel
  private(set) var stack: [SettingsPageData] = []

  init(messenger: FlutterBinaryMessenger) {
    rows = SettingsModel(messenger: messenger)
  }

  var say: SettingsIntents { rows.say }

  func page(_ address: String) -> SettingsPageData? {
    stack.first { $0.address == address }
  }

  func update(_ next: [SettingsPageData]) {
    try? rows.settings(snapshot: SettingsSnapshot(pages: next))
    stack = next
    // Each page over the first is pushed in the order Dart opened them;
    // what a row pushed between them stays, and a page gone takes all over it.
    let opened = next.dropFirst().compactMap(\.address)
    var kept: [SettingsRoute] = []
    var at = 0
    for route in rows.path {
      if case .app(let address) = route {
        guard at < opened.count, opened[at] == address else { break }
        at += 1
      }
      kept.append(route)
    }
    kept += opened[at...].map { SettingsRoute.app($0) }
    if kept != rows.path {
      var moving = Transaction(animation: .smooth(duration: 0.3))
      moving.disablesAnimations = false
      withTransaction(moving) { rows.path = kept }
    }
  }

  /// The path as the user moves it: a page they went back from is closed.
  var path: Binding<[SettingsRoute]> {
    Binding(
      get: { self.rows.path },
      set: { next in
        let left = self.rows.path.dropFirst(next.count).compactMap { route -> String? in
          if case .app(let address) = route { address } else { nil }
        }
        self.rows.path = next
        for address in left.reversed() { self.say.closePage(address: address, completion: ignore) }
      })
  }

  /// Up while a page is open; the sheet swiped away closes them all.
  var presented: Binding<Bool> {
    Binding(
      get: { !self.stack.isEmpty },
      set: { up in
        if !up, let root = self.stack.first?.address {
          self.say.closePage(address: root, completion: ignore)
        }
      })
  }

  /// Leaving [address]: gone at once, or what it asks first.
  func leave(_ address: String) async -> SettingConfirmData? {
    await reply(or: nil) { say.leavePage(address: address, completion: $0) }
  }

  func close(_ address: String) { say.closePage(address: address, completion: ignore) }
}

/// The sheet the app's pages are drawn in, one navigation stack of them.
struct AppPagesSheet: View {
  @Bindable var model: AppPagesModel

  var body: some View {
    NavigationStack(path: model.path) {
      if let root = model.stack.first {
        AppPageView(model: model, page: root, root: true)
          .navigationDestination(for: SettingsRoute.self) { route in
            SettingsDestination(model: model.rows, route: route)
          }
      }
    }
    .interactiveDismissDisabled(model.stack.first?.guarded ?? false)
    #if os(macOS)
      .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 680)
    #endif
  }
}

/// One app page: its sections as the settings draw a page, its subtitle
/// under the title, and its bar: leaving it, and its own actions.
struct AppPageView: View {
  let model: AppPagesModel
  let page: SettingsPageData
  var root = false

  @State private var leaving: SettingConfirmData?

  /// A file or a web page is the whole of its page, not a row of a form.
  private var whole: SettingRowData? {
    let rows = page.rows
    guard rows.count == 1, [.document, .web].contains(rows[0].kind) else { return nil }
    return rows[0]
  }

  var body: some View {
    Group {
      if let row = whole {
        Group {
          if row.kind == .web {
            WebRow(model: model.rows, row: row).ignoresSafeArea(edges: .bottom)
          } else {
            DocumentRow(model: model.rows, row: row)
          }
        }
        .navigationTitle(page.title)
      } else {
        SettingsPageView(model: model.rows, page: page)
      }
    }
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .navigationSubtitleIfAny(page.subtitle)
      // A page that asks before it goes is left by its own button.
      .navigationBarBackButtonHidden(page.guarded && !root)
      .toolbar {
        if root || page.guarded {
          ToolbarItem(placement: .cancellationAction) {
            Button(page.guarded ? "Cancel" : "Done", action: leave)
          }
        }
        ForEach(Array(page.toolbar.compactMap { $0 }.enumerated()), id: \.element.id) {
          index, row in
          ToolbarItem(placement: index == 0 ? .confirmationAction : .primaryAction) {
            ToolbarAction(model: model.rows, row: row)
          }
        }
      }
      .alert(
        leaving?.title ?? "", isPresented: .present($leaving), presenting: leaving
      ) { ask in
        Button(ask.confirmLabel ?? "Discard", role: .destructive) {
          if let address = page.address { model.close(address) }
        }
        Button("Keep Editing", role: .cancel) {}
      } message: { ask in
        Text(ask.message)
      }
  }

  private func leave() {
    guard let address = page.address else { return }
    Task { @MainActor in leaving = await model.leave(address) }
  }
}

/// A page's action in its bar, asking first where it asks.
private struct ToolbarAction: View {
  let model: SettingsModel
  let row: SettingRowData
  @State private var confirm: SettingConfirmData?
  @State private var notice: SettingNoticeData?

  var body: some View {
    Button(role: row.destructive ? .destructive : nil, action: press) {
      if let icon = row.icon {
        Label(row.label ?? row.title, systemImage: icon.symbol)
      } else {
        Text(row.label ?? row.title)
      }
    }
    .disabled(!row.enabled || row.busy)
    .help(row.detail ?? row.label ?? row.title)
    .asking($confirm, $notice) { run() }
  }

  private func press() {
    Task { @MainActor in
      guard let ask = await model.ask(row.id) else { return run() }
      if ask.cancelled { return }
      if ask.brief {
        notice = SettingNoticeData(title: nil, message: ask.message)
        return
      }
      confirm = ask
    }
  }

  private func run() {
    Task { @MainActor in notice = await model.run(row.id) }
  }
}

extension View {
  @ViewBuilder func navigationSubtitleIfAny(_ subtitle: String?) -> some View {
    #if os(iOS)
      if let subtitle, #available(iOS 26, *) {
        navigationSubtitle(subtitle)
      } else {
        self
      }
    #else
      if let subtitle {
        navigationSubtitle(subtitle)
      } else {
        self
      }
    #endif
  }
}

/// Presents the app's pages while any is open: over the window, or on iOS
/// over the settings sheet while it is up, a sheet being presented only from
/// the one on top.
struct AppPagesPresenter: ViewModifier {
  /// Whether this is the settings sheet's presenter rather than the window's.
  var inSettings = false

  private var here: Bool {
    #if os(iOS)
      (SettingsModel.shared?.presented ?? false) == inSettings
    #else
      !inSettings
    #endif
  }

  func body(content: Content) -> some View {
    if let pages = AppPagesModel.shared {
      content.sheet(
        isPresented: Binding(
          get: { here && pages.presented.wrappedValue },
          set: { pages.presented.wrappedValue = $0 })
      ) { AppPagesSheet(model: pages) }
    } else {
      content
    }
  }
}

/// A file's text: markdown rendered while it is read, anything else set in
/// the code face, and an editor while the page says it is being edited,
/// each pause in the typing said back so Dart holds the draft.
struct DocumentRow: View {
  let model: SettingsModel
  let row: SettingRowData

  @State private var text = ""
  @State private var sending: Task<Void, Never>?

  var body: some View {
    Group {
      if row.editing {
        TextEditor(text: $text)
          .font(.system(size: 13, design: .monospaced))
          .autocorrectionDisabled()
          #if os(iOS)
            .textInputAutocapitalization(.never)
          #endif
          .scrollContentBackground(.hidden)
          .padding(.horizontal, 8)
          .onChange(of: text) { _, now in send(now) }
      } else if (row.text ?? "").isEmpty {
        ContentUnavailableView("This file is empty", systemImage: "doc")
      } else if row.markdown {
        ScrollView {
          MarkdownBlocks(text: row.text ?? "")
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
      } else {
        ScrollView([.vertical, .horizontal]) {
          Text(row.text ?? "")
            .font(.system(size: 13, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
      }
    }
    .background(Color.pageBackground)
    .onAppear { text = row.text ?? "" }
    .onChange(of: row.editing) { _, editing in
      if editing { text = row.text ?? "" }
    }
    .onDisappear { flush() }
  }

  /// Said as it is typed, so Save writes what is on screen; a long file
  /// once the typing pauses, rather than every key.
  private func send(_ now: String) {
    sending?.cancel()
    if now.utf8.count < 64 * 1024 {
      sending = nil
      model.say.setText(id: row.id, text: now, completion: ignore)
      return
    }
    sending = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      model.say.setText(id: row.id, text: now, completion: ignore)
    }
  }

  private func flush() {
    guard sending != nil else { return }
    sending?.cancel()
    model.say.setText(id: row.id, text: text, completion: ignore)
  }
}
