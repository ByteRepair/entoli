import SwiftUI

extension SidebarSnapshot {
  static let initial = SidebarSnapshot(
    project: ProjectChoice(label: "", glyph: .home, omada: false, count: 0), pages: [],
    groups: [], query: "", projects: [], devices: [], omadaByDefault: false)
}

extension SidebarRow: Identifiable {}

extension SidebarGroup: Identifiable {
  var id: String { "\(period)-\(month ?? 0)" }
}

/// The native sidebar: the project switcher over the project's chats, the
/// search field the system puts at the top of a sidebar, a row menu per chat,
/// and its dialogs. Everything it shows is Dart's, and everything it does is
/// an intent; the only state here is what a dialog holds while it is open.
struct SidebarView: View {
  var model: ShellModel

  @State private var query = ""
  @State private var renaming: SidebarRow?
  @State private var title = ""
  @State private var deleting: SidebarRow?
  @State private var creating = false

  private var state: SidebarSnapshot { model.sidebar }

  /// An iPhone's drawer rather than a split view's column.
  let collapsed: Bool

  /// The chat that is open, highlighted — except on an iPhone, whose lists
  /// keep no selection: there the drawer is `compactColumn`'s alone, and a
  /// pick only asks for the detail.
  private var selection: Binding<String?> {
    Binding(
      get: { collapsed ? nil : state.selected },
      set: { id in
        guard let id else { return }
        model.say.sidebar.openChat(id: id) { _ in }
        model.showDetail()
      })
  }

  var body: some View {
    List(selection: selection) {
      ForEach(state.groups) { group in
        Section {
          ForEach(group.rows) { row in
            ChatRow(row: row)
              .tag(row.id)
              .contextMenu { if row.mutable { menu(row) } }
          }
        } header: {
          if let heading = group.heading { Text(heading) }
        }
      }
    }
    .overlay {
      if let empty = state.empty {
        Text(empty.words)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding()
      }
    }
    .searchable(text: $query, placement: .sidebar, prompt: "Search chats")
    #if os(iOS)
      // The project header is the list's title; no large one above it.
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .onChange(of: query) { _, query in
      if query != state.query { model.say.sidebar.search(query: query) { _ in } }
    }
    .onChange(of: state.query) { _, query in self.query = query }
    .safeAreaInset(edge: .top, spacing: 0) {
      ProjectHeader(model: model, creating: $creating)
    }
    .toolbar {
      ToolbarItem {
        Button {
          model.say.sidebar.newChat { _ in }
          model.showDetail()
        } label: {
          Label("New Chat", systemImage: "square.and.pencil")
        }
        .help("New chat")
      }
      #if os(iOS)
        // What the menu bar holds on a Mac: the app's own pages.
        ToolbarItem(placement: .topBarLeading) {
          Menu {
            appPage(.settings, "Settings", "gearshape")
            appPage(.profile, "Profile", "person.crop.circle")
            appPage(.marketplace, "Marketplace", "storefront")
          } label: {
            Label("More", systemImage: "ellipsis")
          }
        }
      #endif
    }
    .alert("Rename chat", isPresented: .present($renaming)) {
      TextField("Chat title", text: $title)
      Button("Rename") {
        if let row = renaming { model.say.sidebar.rename(id: row.id, title: title) { _ in } }
      }
      Button("Cancel", role: .cancel) {}
    }
    .alert(
      "Delete chat?", isPresented: .present($deleting),
      presenting: deleting
    ) { row in
      Button("Delete", role: .destructive) { model.say.sidebar.delete(id: row.id) { _ in } }
      Button("Cancel", role: .cancel) {}
    } message: { row in
      Text("Delete \u{201C}\(row.shownTitle)\u{201D}? This cannot be undone.")
    }
    .sheet(isPresented: $creating) {
      NewProjectSheet(model: model, omada: state.omadaByDefault)
    }
  }

  /// One of the app's pages, opened over the chat: on an iPhone the chat is
  /// the column to show it in.
  private func appPage(_ page: ShellPage, _ label: String, _ symbol: String) -> some View {
    Button {
      model.say.sidebar.openPage(page: page) { _ in }
      model.showDetail()
    } label: {
      Label(label, systemImage: symbol)
    }
  }

  /// The row's menu: Pin, Rename, Move, Delete, the chat commands of the
  /// Flutter sidebar's row, less Move for a mirror.
  @ViewBuilder private func menu(_ row: SidebarRow) -> some View {
    Button(row.pinned ? "Unpin" : "Pin") {
      model.say.sidebar.pin(id: row.id, pinned: !row.pinned) { _ in }
    }
    Button("Rename…") {
      title = row.title
      renaming = row
    }
    if !row.remote {
      Menu("Move to Project") {
        ForEach(state.projects, id: \.self) { target in
          Button(target.label) {
            model.say.sidebar.move(id: row.id, project: target.project) { _ in }
          }
          .disabled(target.project == state.project.project)
        }
      }
    }
    Divider()
    Button("Delete…", role: .destructive) { deleting = row }
  }
}

/// One chat: a spinner while it runs, its title, the hourglass where it will
/// expire, and "offline" under a mirror whose device is away. The spinner's
/// slot is there whether or not a turn is, so the title never moves.
private struct ChatRow: View {
  let row: SidebarRow

  var body: some View {
    HStack(spacing: 6) {
      ZStack {
        if row.busy { ProgressView().controlSize(.mini) }
      }
      .frame(width: 14)
      VStack(alignment: .leading, spacing: 1) {
        Text(row.shownTitle).lineLimit(1)
        if row.offline {
          Text("offline").font(.caption).foregroundStyle(.red)
        }
      }
      Spacer(minLength: 0)
      if row.temporary {
        Image(systemName: "hourglass").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

/// The project being shown, as a menu of every project to switch to, and the
/// pages it has beside its chats.
private struct ProjectHeader: View {
  var model: ShellModel
  @Binding var creating: Bool

  private var state: SidebarSnapshot { model.sidebar }

  var body: some View {
    HStack(spacing: 4) {
      Menu {
        Section {
          ForEach(state.projects, id: \.self) { item($0) }
        }
        if !state.devices.isEmpty {
          Section("Other Devices") {
            ForEach(state.devices, id: \.self) { item($0) }
          }
        }
        Divider()
        Button("New Project…") { creating = true }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: (state.project.glyph ?? .folder).systemImage)
          Text(state.project.label)
            .font(.headline)
            .italic(state.project.omada)
            .lineLimit(1)
          Spacer(minLength: 0)
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .help("Switch project")
      page(.workspace, "folder", "Workspace")
      page(.memories, "brain", "Memories")
      page(.projectSettings, "gearshape", "Project settings")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  /// A project in the menu: its own icon beside its name, always, and the
  /// system's checkmark on the one being shown — a toggle, which is how a
  /// menu draws a choice that is on, rather than the icon given up for it.
  private func item(_ choice: ProjectChoice) -> some View {
    let current = choice.device == state.project.device && choice.project == state.project.project
    return Toggle(
      isOn: Binding(
        get: { current },
        set: { _ in
          model.say.sidebar.selectProject(device: choice.device, project: choice.project) { _ in }
          // The Flutter sidebar closes on a project picked, leaving its
          // new-chat screen in front.
          model.showDetail()
        })
    ) {
      Label {
        Text(choice.count > 0 ? "\(choice.label)  \(choice.count)" : choice.label)
          .italic(choice.omada)
      } icon: {
        Image(systemName: (choice.glyph ?? .folder).systemImage)
      }
      .labelStyle(.titleAndIcon)
    }
  }

  @ViewBuilder private func page(_ page: ShellPage, _ symbol: String, _ label: String) -> some View {
    if state.pages.contains(page) {
      Button {
        model.say.sidebar.openPage(page: page) { _ in }
        model.showDetail()
      } label: {
        Image(systemName: symbol)
      }
      .buttonStyle(.borderless)
      .help(label)
    }
  }
}

/// A project made on the device the sidebar shows: a name, a description, and
/// whether it runs Omada. It stays open, spinning, until the project is made,
/// and says so where it could not be.
struct NewProjectSheet: View {
  var model: ShellModel
  @Environment(\.dismiss) private var dismiss

  /// Told once the project is made: the palette closes itself with it.
  var made: () -> Void = {}

  @State private var name = ""
  @State private var description = ""
  @State var omada: Bool
  @State private var making = false
  @State private var failure: String?

  init(model: ShellModel, omada: Bool, made: @escaping () -> Void = {}) {
    self.model = model
    self.made = made
    _omada = State(initialValue: omada)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New Project").font(.title2.bold())
      Form {
        TextField("Name", text: $name)
        TextField("Description", text: $description, prompt: Text("What would you like to discuss?"), axis: .vertical)
          .lineLimit(2...4)
        Toggle("Omada", isOn: $omada)
      }
      .formStyle(.grouped)
      if let failure {
        Text(failure).font(.callout).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button {
          making = true
          failure = nil
          model.say.sidebar.createProject(
            name: name, description: description, omada: omada
          ) { result in
            making = false
            let error = (try? result.get()) ?? nil
            if let error {
              failure = error.words
            } else {
              dismiss()
              made()
            }
          }
        } label: {
          if making { ProgressView().controlSize(.small) } else { Text("Create") }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(making || name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 420)
  }
}

/// This frontend's words for the sidebar's state.
extension SidebarGroup {
  /// A month of an earlier year says the year, or two Augusts would read as
  /// one.
  var heading: String? {
    switch period {
    case .none: return nil
    case .pinned: return "Pinned"
    case .today: return "Today"
    case .yesterday: return "Yesterday"
    case .previousWeek: return "Previous 7 Days"
    case .previousMonth: return "Previous 30 Days"
    case .month:
      guard let month else { return nil }
      let date = Date(timeIntervalSince1970: Double(month) / 1000)
      let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
      return date.formatted(sameYear ? .dateTime.month(.wide) : .dateTime.month(.wide).year())
    }
  }
}

extension SidebarEmpty {
  var words: String {
    switch self {
    case .noChats: "No chats in this project yet."
    case .noMirrored: "Nothing mirrored from this device yet."
    case .noMatch: "No chat\u{2019}s title matches that."
    }
  }
}

extension ProjectError {
  var words: String {
    switch self {
    case .badName: "That is not a name a project can have."
    case .failed: "The project could not be created."
    }
  }
}

extension SidebarRow {
  var shownTitle: String { title.orUntitled }
}

extension String {
  /// A chat's title as shown, which a chat not named yet has none of.
  var orUntitled: String { isEmpty ? "Untitled" : self }
}
