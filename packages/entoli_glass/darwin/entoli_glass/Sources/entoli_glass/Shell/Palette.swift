import SwiftUI

/// `PaletteSnapshot`.
struct PaletteState: Decodable, Equatable {
  struct Item: Decodable, Equatable, Identifiable {
    var id: String
    var label: String
    var chat: String?
    var device: String?
    var project: String?
    var symbol = ""
    var omada = false
    var trailing = ""
    var busy = false
    var current = false
  }

  struct Section: Decodable, Equatable {
    var heading: String
    var items: [Item]
  }

  var open = false
  var query = ""
  var sections: [Section] = []
  var serial = 0
  var omadaByDefault = false

  var items: [Item] { sections.flatMap(\.items) }
}

/// The project palette, Cmd+K's, as a panel over the window in the system's
/// glass: a search field over the projects and every chat, the arrow keys
/// moving through them, Return taking one and Escape leaving. Dart's
/// `PalettePublisher` lists and narrows the rows by `ProjectPalette`'s rules;
/// a pick is an intent.
struct PaletteView: View {
  @ObservedObject var model: ShellModel

  @State private var query = ""
  @State private var active: String?
  @State private var creating = false
  @FocusState private var focused: Bool

  private var palette: PaletteState { model.palette }

  private func say(_ name: String, _ args: [String: Any?] = [:]) {
    model.intent("palette", ["name": name, "args": args.mapValues { $0 ?? NSNull() }])
  }

  /// The row the arrows are on: the one moved to, else the project shown
  /// while nothing is typed, else the first.
  private var activeId: String? {
    let items = palette.items
    if let active, items.contains(where: { $0.id == active }) { return active }
    if query.isEmpty, let current = items.first(where: { $0.current && $0.chat == nil }) {
      return current.id
    }
    return items.first?.id
  }

  private func move(_ by: Int) {
    let items = palette.items
    guard !items.isEmpty else { return }
    let at = items.firstIndex { $0.id == activeId } ?? 0
    active = items[min(max(at + by, 0), items.count - 1)].id
  }

  private func pick(_ item: PaletteState.Item) {
    if let chat = item.chat {
      say("pickChat", ["chat": chat])
      model.showDetail()
    } else {
      say("pickProject", ["device": item.device, "project": item.project])
    }
  }

  var body: some View {
    ZStack(alignment: .top) {
      // Clicking outside it closes it, as a popover does.
      Color.black.opacity(0.12)
        .ignoresSafeArea()
        .onTapGesture { say("close") }
      panel
        .frame(maxWidth: 560)
        .padding(.top, 80)
        .padding(.horizontal, 24)
    }
    .sheet(isPresented: $creating) {
      NewProjectSheet(model: model, omada: palette.omadaByDefault) { say("close") }
    }
  }

  private var panel: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Switch project or open a chat", text: $query)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($focused)
          .onSubmit {
            if let item = palette.items.first(where: { $0.id == activeId }) { pick(item) }
          }
          .onKeyPress(.upArrow) {
            move(-1)
            return .handled
          }
          .onKeyPress(.downArrow) {
            move(1)
            return .handled
          }
          .onKeyPress(.escape) {
            say("close")
            return .handled
          }
        Button {
          creating = true
        } label: {
          Label("New Project", systemImage: "plus")
        }
        .glassButton()
        .help("New project")
      }
      .padding(14)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
            if palette.items.isEmpty {
              Text("Nothing matches that.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            ForEach(Array(palette.sections.enumerated()), id: \.offset) { index, section in
              if index > 0 && section.heading.isEmpty { Divider().padding(.vertical, 4) }
              if !section.heading.isEmpty {
                Text(section.heading)
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 12)
                  .padding(.top, 10)
                  .padding(.bottom, 2)
              }
              ForEach(section.items) { row($0) }
            }
          }
          .padding(8)
        }
        .frame(maxHeight: 420)
        .onChange(of: activeId) { _, id in
          if let id { proxy.scrollTo(id) }
        }
      }
    }
    .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .shadow(color: .black.opacity(0.2), radius: 30, y: 12)
    .onAppear {
      query = palette.query
      focused = true
    }
    .onChange(of: query) { _, query in
      active = nil
      if query != palette.query { say("search", ["query": query]) }
    }
  }

  private func row(_ item: PaletteState.Item) -> some View {
    let on = item.id == activeId
    return Button {
      pick(item)
    } label: {
      HStack(spacing: 10) {
        ZStack {
          if item.busy {
            ProgressView().controlSize(.mini)
          } else if item.chat == nil {
            Image(systemName: item.symbol.isEmpty ? "folder" : item.symbol)
          } else {
            Image(systemName: "bubble.left")
          }
        }
        .frame(width: 18)
        .foregroundStyle(.secondary)
        Text(item.label).italic(item.omada).lineLimit(1)
        if item.current {
          Image(systemName: "checkmark").font(.caption).foregroundStyle(.tint)
        }
        Spacer(minLength: 8)
        Text(item.trailing).font(.callout).foregroundStyle(.secondary).lineLimit(1)
      }
      .padding(.horizontal, 10)
      .frame(height: 32)
      .contentShape(Rectangle())
      .background {
        if on {
          RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.tint.opacity(0.2))
        }
      }
    }
    .buttonStyle(.plain)
    .id(item.id)
    .onHover { if $0 { active = item.id } }
  }
}
