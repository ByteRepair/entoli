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
  /// What the sheet draws: the stack, or as it last stood while the sheet
  /// closes over it, so nothing in it loses its page as it goes.
  private(set) var shown: [SettingsPageData] = []

  init(messenger: FlutterBinaryMessenger) {
    rows = SettingsModel(messenger: messenger)
  }

  var say: SettingsIntents { rows.say }

  /// Whether what is open is left only by its own buttons: the first
  /// launch's setup and the welcome.
  var held: Bool { stack.first?.held ?? false }

  func page(_ address: String) -> SettingsPageData? {
    shown.first { $0.address == address }
  }

  func update(_ next: [SettingsPageData]) {
    // Closed: the sheet goes as it stood, its rows and what they pushed
    // kept until the next stack opens. Taken away at once, a pushed page lost
    // its destination and drew the system's warning sign as the sheet went.
    guard !next.isEmpty else {
      stack = []
      return
    }
    try? rows.settings(snapshot: SettingsSnapshot(pages: next))
    // Opened anew, or on another page, it keeps nothing a row pushed: the
    // sheet Escape closed over a model list reopened on it, blank.
    let fresh = stack.first?.address != next.first?.address
    stack = next
    shown = next
    // Each page over the first is pushed in the order Dart opened them;
    // what a row pushed between them stays, and a page gone takes all over it.
    let opened = next.dropFirst().compactMap(\.address)
    var kept: [SettingsRoute] = []
    var at = 0
    for route in fresh ? [] : rows.path {
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

/// The app's pages as one navigation stack, [root] at its foot.
private struct AppPagesStack: View {
  let model: AppPagesModel
  let root: SettingsPageData?

  var body: some View {
    NavigationStack(path: model.path) {
      if let root {
        AppPageView(model: model, page: root, root: true)
          .navigationDestination(for: SettingsRoute.self) { route in
            SettingsDestination(model: model.rows, route: route)
          }
      }
    }
  }
}

extension View {
  /// Asks before a page of unsaved edits goes, [close] taking it away.
  fileprivate func leavingAlert(
    _ leaving: Binding<SettingConfirmData?>, close: @escaping () -> Void
  ) -> some View {
    alert(
      leaving.wrappedValue?.title ?? "", isPresented: .present(leaving),
      presenting: leaving.wrappedValue
    ) { ask in
      Button(ask.confirmLabel ?? "Discard", role: .destructive, action: close)
      Button("Keep Editing", role: .cancel) {}
    } message: { ask in
      Text(ask.message)
    }
  }
}

/// The sheet the app's pages are drawn in, one navigation stack of them.
struct AppPagesSheet: View {
  @Bindable var model: AppPagesModel

  var body: some View {
    AppPagesStack(model: model, root: model.shown.first)
    .interactiveDismissDisabled((model.stack.first?.guarded ?? false) || model.held)
    #if os(macOS)
      .environment(\.ownBar, true)
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

  /// In the card, which draws the page's bar itself.
  @Environment(\.appPagesCard) private var card
  @State private var leaving: SettingConfirmData?
  @State private var adding: Adding?

  struct Adding: Identifiable {
    let id: String
  }

  /// The lists added to from the bar rather than a row under them.
  private var barAdds: [SettingRowData] {
    page.sections.compactMap { $0 }.flatMap { $0.rows.compactMap { $0 } }
      .filter { $0.kind == .collection && $0.editable && $0.addIcon != nil }
  }

  /// The row the page says is the whole of it — a file, a web page — rather
  /// than a row of a form.
  private var whole: SettingRowData? {
    let sections = page.sections.compactMap { $0 }
    guard sections.count == 1, sections[0].fills else { return nil }
    return sections[0].rows.first ?? nil
  }

  var body: some View {
    Group {
      if let row = whole {
        Group {
          if row.kind == .web {
            WebRow(model: model.rows, row: row).ignoresSafeArea(edges: .bottom)
          } else {
            DocumentRow(model: model.rows, row: row, controls: true)
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
        if !card {
          if (root && !page.held) || page.guarded {
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
          ForEach(barAdds, id: \.id) { row in
            ToolbarItem(placement: .primaryAction) {
              Button {
                adding = Adding(id: row.id)
              } label: {
                Label(row.addLabel ?? row.title, systemImage: row.addIcon?.symbol ?? "plus")
              }
              .help(row.addLabel ?? row.title)
            }
          }
        }
      }
      .sheet(item: $adding) { adding in
        FormSheet(model: model.rows, id: adding.id, index: nil)
      }
      .leavingAlert($leaving) {
        if let address = page.address { model.close(address) }
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

  var body: some View {
    ActionPress(model: model, row: row, role: row.destructive ? .destructive : nil) {
      ActionLabel(row: row)
    }
    .disabled(!row.enabled || row.busy)
    .help(row.detail ?? row.label ?? row.title)
  }
}

extension View {
  @ViewBuilder func navigationSubtitleIfAny(_ subtitle: String?) -> some View {
    if let subtitle, #available(iOS 26, *) {
      navigationSubtitle(subtitle)
    } else {
      self
    }
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
      #if os(macOS)
        let carded = here && pages.held && !pages.stack.isEmpty
        content
          .sheet(
            isPresented: Binding(
              get: { here && !pages.held && pages.presented.wrappedValue },
              set: { pages.presented.wrappedValue = $0 })
          ) { AppPagesSheet(model: pages) }
          .overlay {
            if carded {
              AppPagesCard(model: pages)
                .transition(.asymmetric(insertion: .identity, removal: .move(edge: .bottom).combined(with: .opacity)))
            }
          }
          .animation(.smooth(duration: 0.4), value: carded)
      #else
        content.sheet(
          isPresented: Binding(
            get: { here && pages.presented.wrappedValue },
            set: { pages.presented.wrappedValue = $0 })
        ) { AppPagesSheet(model: pages) }
      #endif
    } else {
      content
    }
  }
}

extension EnvironmentValues {
  @Entry var appPagesCard = false

  /// Whether a page draws its own bar rather than the toolbar's: in a Mac's
  /// sheet, whose toolbar sets the title on a row of its own under its items.
  @Entry var ownBar = false
}

#if os(macOS)
  /// A held stack, the first launch's setup and the welcome, as a card
  /// risen from the window's bottom edge over the dimmed window, the way
  /// Apple's own onboarding comes up. A sheet would drop from the title bar
  /// and close on Escape; this is left only by its own buttons. It is drawn
  /// in the window, whose toolbar is hidden under it, so it draws its bar
  /// itself: the title on top, the page's buttons along the bottom.
  struct AppPagesCard: View {
    @Bindable var model: AppPagesModel
    @State private var leaving: SettingConfirmData?
    /// Up from below the window's edge once it is in the window, so it
    /// rises at launch too, where it is there from the first frame.
    @State private var risen = false
    private let shape = UnevenRoundedRectangle(
      topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)

    /// The page on top, where it is one of the app's rather than what a row
    /// pushed.
    private var top: SettingsPageData? {
      guard let last = model.rows.path.last else { return model.stack.first }
      if case .app(let address) = last { return model.page(address) }
      return nil
    }

    var body: some View {
      ZStack {
        // Nothing behind it answers while it is up.
        Rectangle().fill(.black.opacity(risen ? 0.25 : 0)).ignoresSafeArea()
          .contentShape(Rectangle()).onTapGesture {}
        GeometryReader { space in
          let height = min(760, space.size.height - 40)
          VStack(spacing: 0) {
            header
            AppPagesStack(model: model, root: model.stack.first)
            footer
          }
          .environment(\.appPagesCard, true)
          .frame(width: min(720, space.size.width - 48), height: height)
          .background(.windowBackground, in: shape)
          .clipShape(shape)
          .overlay(shape.strokeBorder(.separator.opacity(0.5)))
          .shadow(color: .black.opacity(0.2), radius: 24, y: -2)
          // Flush with the window's bottom edge, and below it until risen.
          .offset(y: risen ? 0 : height + 60)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .ignoresSafeArea(edges: .bottom)
      }
      // A beat first: at launch it appears before the window is on screen.
      .task {
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.spring(duration: 0.55, bounce: 0.12)) { risen = true }
      }
      .leavingAlert($leaving) {
        if let address = top?.address { model.close(address) }
      }
    }

    private var header: some View {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        if !model.rows.path.isEmpty {
          Button(action: back) { Image(systemName: "chevron.backward") }
            .modifier(GlassButton())
            .buttonBorderShape(.circle)
            .help("Back")
        }
        VStack(alignment: .leading, spacing: 2) {
          if let top {
            Text(top.title).font(.title2.bold())
            if let subtitle = top.subtitle {
              Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 24)
      .padding(.top, 22)
      .padding(.bottom, 8)
    }

    /// The page's own buttons: the first, its going on, at the trailing
    /// end and prominent; the rest, going back among them, before it.
    @ViewBuilder private var footer: some View {
      let actions = top?.toolbar.compactMap { $0 } ?? []
      if !actions.isEmpty {
        HStack(spacing: 12) {
          ForEach(actions.dropFirst(), id: \.id) { row in
            ToolbarAction(model: model.rows, row: row).modifier(GlassButton())
          }
          Spacer(minLength: 0)
          ToolbarAction(model: model.rows, row: actions[0])
            .modifier(GlassButton(prominent: true))
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
      }
    }

    /// Back from what is on top: a page of the app's asked first, what a
    /// row pushed simply popped.
    private func back() {
      if let address = top?.address, top?.held != true {
        Task { @MainActor in leaving = await model.leave(address) }
      } else if top == nil {
        model.path.wrappedValue = Array(model.rows.path.dropLast())
      }
    }
  }
#endif

/// A file's text: markdown rendered while it is read, anything else in the
/// code editor, read-only until the page says it is being edited, each pause
/// in the typing said back so Dart holds the draft.
struct DocumentRow: View {
  let model: SettingsModel
  let row: SettingRowData
  /// Whether it is the whole of its page, whose bar carries the editor's
  /// menu.
  var controls = false

  @State private var text = ""
  @State private var sending: Task<Void, Never>?

  /// The name the grammar is chosen by: the file's, which titles the row,
  /// or markdown's for what is read as markdown.
  private var name: String { row.markdown ? "text.md" : row.title }

  private var code: Bool { row.editing || (!row.markdown && !(row.text ?? "").isEmpty) }

  var body: some View {
    Group {
      if row.editing {
        CodeEditor(text: $text, name: name, editable: true, placeholder: row.prompt)
          .onChange(of: text) { _, now in send(now) }
      } else if (row.text ?? "").isEmpty {
        ContentUnavailableView("This file is empty", systemImage: "doc")
      } else if row.markdown {
        ScrollView {
          DocumentMarkdown(text: row.text ?? "")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
      } else {
        CodeEditor(text: .constant(row.text ?? ""), name: name, editable: false)
      }
    }
    .background(Color.pageBackground)
    .toolbar {
      if controls && code {
        ToolbarItem(placement: .primaryAction) { CodeEditorMenu() }
      }
    }
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
