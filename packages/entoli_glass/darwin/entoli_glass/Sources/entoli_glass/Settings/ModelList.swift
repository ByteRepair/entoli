import SwiftUI

/// Where a model picker goes: every model the role can use, to search and
/// compare, under the entries that store less than a model — the null entry
/// and each provider's Default — and the favourites, in the order they were
/// starred. A card says what a model costs and can do; a star keeps it for
/// every picker; one added by hand can be edited and deleted. What it holds
/// is Dart's, asked again after anything changes it.
struct ModelList: View {
  let model: SettingsModel
  let row: SettingRowData

  @State private var data: ModelPickerData?
  /// [data]'s models, and what a search matches each by, kept apart from the
  /// body: a search redraws it on every key.
  @State private var cards: [ModelCardData] = []
  @State private var haystacks: [String] = []
  @State private var search = ""
  @State private var reasoning = false
  @State private var seesImages = false
  @State private var provider: String?
  @State private var editing: Editing?
  @State private var deleting: ModelCardData?

  /// The model a form is open for: a new one where [modelId] is nil, on
  /// [providerId] where the picker is narrowed to one.
  struct Editing: Identifiable {
    let providerId: String?
    let modelId: String?
    var id: String { "\(providerId ?? "")/\(modelId ?? "")" }
  }

  private var shown: [ModelCardData] {
    let words = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    return zip(cards, haystacks).filter { card, hay in
      words.allSatisfy(hay.contains)
        && (!reasoning || card.reasoning)
        && (!seesImages || card.readsImages)
        && (provider == nil || card.providerId == provider)
    }.map(\.0)
  }

  private func show(_ next: ModelPickerData?) {
    data = next
    cards = next?.models.compactMap { $0 } ?? []
    haystacks = cards.map { "\($0.name) \($0.modelId) \($0.providerName)".lowercased() }
  }

  // A grouped Form rather than a List: a Mac's List sizes rows of varying
  // height from an estimate until they scroll, drawing every card squashed.
  var body: some View {
    Form {
      if let data {
        content(data)
      } else {
        HStack { Spacer(); ProgressView(); Spacer() }
      }
    }
    .formStyle(.grouped)
    .searchable(text: $search, prompt: "Search \(cards.count) models")
    .topBar { filters }
    .navigationTitle(data?.title ?? "")
    .toolbar {
      if data?.canAdd == true {
        ToolbarItem(placement: .primaryAction) {
          Button {
            editing = Editing(providerId: provider, modelId: nil)
          } label: {
            Label("Add model", systemImage: "plus")
          }
        }
      }
    }
    .sheet(item: $editing, onDismiss: reload) { editing in
      FormSheet(
        load: { await model.modelForm(row.id, editing.providerId, editing.modelId, $0) },
        save: { await model.submitModelForm(row.id, editing.providerId, editing.modelId, $0) })
    }
    .alert(
      "Delete \(deleting?.name ?? "")?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      presenting: deleting
    ) { card in
      Button("Delete", role: .destructive) {
        model.say.deleteModel(providerId: card.providerId, modelId: card.modelId, completion: ignore)
        reload()
      }
      Button("Cancel", role: .cancel) {}
    } message: { card in
      Text(
        "It is no longer offered for \(card.providerName). A model already picked keeps its id "
          + "until another is picked.")
    }
    .task { show(await model.models(row.id)) }
  }

  @ViewBuilder private func content(_ data: ModelPickerData) -> some View {
    if !data.fetched {
      Section {
        Label {
          Titled(
            title: "Only the default models for now",
            detail: "The full catalog comes from models.dev and arrives the next time Entoli "
              + "is online.")
        } icon: {
          Image(systemName: "icloud.slash")
        }
      }
    }
    if search.isEmpty {
      Section("Quick picks") {
        ForEach(Array(data.quick.compactMap { $0 }.enumerated()), id: \.offset) { _, quick in
          Button {
            pick(quick.providerId, nil)
          } label: {
            HStack(spacing: 12) {
              Image(systemName: quick.providerId == nil ? "nosign" : "sparkles")
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
              Titled(title: quick.title, detail: quick.subtitle)
              Spacer()
              if quick.selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      let starred = data.favourites.compactMap { $0 }.map(Int.init).filter(cards.indices.contains)
      if !starred.isEmpty {
        Section("Favourites") {
          ForEach(starred, id: \.self) { card(cards[$0]) }
        }
      }
    }
    let matching = shown
    Section(matching.count == 1 ? "1 model" : "\(matching.count) models") {
      if matching.isEmpty {
        empty(data)
      } else {
        ForEach(matching, id: \.key) { card($0) }
      }
    }
  }

  /// The filters over the list: what the model does, and whose it is.
  private var filters: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        chip("Reasoning", "brain", on: reasoning) { reasoning.toggle() }
        if data?.chat == true {
          chip("Sees images", "eye", on: seesImages) { seesImages.toggle() }
        }
        let providers = data?.providers.compactMap { $0 } ?? []
        if providers.count > 1 {
          ForEach(providers, id: \.id) { p in
            chip(p.name, "cloud", on: provider == p.id) {
              provider = provider == p.id ? nil : p.id
            }
          }
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
    }
  }

  private func chip(_ label: String, _ symbol: String, on: Bool, _ action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Label(label, systemImage: on ? "checkmark" : symbol)
        .font(.callout)
        .padding(.horizontal, 4)
    }
    .glassButton(prominent: on)
  }

  private func card(_ card: ModelCardData) -> some View {
    Button {
      pick(card.providerId, card.modelId)
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {
          Monogram(name: card.providerName, hue: card.hue)
          VStack(alignment: .leading, spacing: 2) {
            Text(card.name).font(.headline).lineLimit(1)
            Text("\(card.providerName) · \(card.modelId)")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          if card.selected {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
          }
          Button {
            model.say.toggleFavourite(
              providerId: card.providerId, modelId: card.modelId, completion: ignore)
            reload()
          } label: {
            Image(systemName: card.favourite ? "star.fill" : "star")
              .foregroundStyle(card.favourite ? Color.accentColor : .secondary)
          }
          .buttonStyle(.borderless)
          .help(card.favourite ? "Remove from favourites" : "Add to favourites")
        }
        FlowLayout(spacing: 6, centred: false) {
          if let context = card.context { Tag(symbol: "chart.pie", text: "\(context) context") }
          if let price = card.price { Tag(symbol: "dollarsign.circle", text: price) }
          if card.toolCall { Tag(symbol: "wrench.and.screwdriver", text: "Tools") }
          if card.reasoning { Tag(symbol: "brain", text: "Reasoning") }
          if card.readsImages { Tag(symbol: "eye", text: "Sees images") }
          if card.makesImages { Tag(symbol: "paintbrush", text: "Makes images") }
          if card.transcribes { Tag(symbol: "ear", text: "Transcribes") }
          if card.speaks { Tag(symbol: "waveform", text: "Speaks") }
          if card.custom { Tag(symbol: "pencil", text: "Added by you") }
        }
      }
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(card.selected ? Color.accentColor.opacity(0.12) : nil)
    .contextMenu {
      Button(card.favourite ? "Remove from favourites" : "Add to favourites") {
        model.say.toggleFavourite(
          providerId: card.providerId, modelId: card.modelId, completion: ignore)
        reload()
      }
      if card.custom {
        Button("Edit") { editing = Editing(providerId: card.providerId, modelId: card.modelId) }
        Button("Delete", role: .destructive) { deleting = card }
      }
    }
  }

  @ViewBuilder private func empty(_ data: ModelPickerData) -> some View {
    // Nothing at all to offer is the role's to say; nothing matching, the
    // search's.
    let none = cards.isEmpty
    VStack(spacing: 10) {
      Image(systemName: "binoculars").font(.largeTitle).foregroundStyle(.secondary)
      Text(none ? data.emptyTitle ?? "No model matches" : "No model matches")
        .font(.headline)
      Text(
        none
          ? data.emptyNote ?? ""
          : "Not every model is in the catalog. A fine-tune or a private deployment can be "
            + "added by hand."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      if data.canAdd {
        Button("Add model") { editing = Editing(providerId: provider, modelId: nil) }
          .glassButton()
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }

  private func pick(_ providerId: String?, _ modelId: String?) {
    model.say.setModel(id: row.id, providerId: providerId, modelId: modelId, completion: ignore)
    model.back()
  }

  private func reload() {
    Task { @MainActor in show(await model.models(row.id)) }
  }
}

/// One thing a model is or does, on its card.
private struct Tag: View {
  let symbol: String
  let text: String

  // Not a Label: a list row draws a Label's icon in a column of its own.
  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: symbol)
      Text(text)
    }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(.quaternary.opacity(0.6), in: Capsule())
      .fixedSize()
  }
}

/// The provider's initial on a colour of its own, so a long list reads by
/// provider at a glance: the hue Dart gives it, so a provider wears the same
/// colour on both frontends.
private struct Monogram: View {
  let name: String
  let hue: Int64
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let dark = scheme == .dark
    let hue = Double(hue) / 360
    Text(name.first.map { String($0).uppercased() } ?? "?")
      .font(.callout.weight(.semibold))
      .foregroundStyle(Self.hsl(hue, 0.5, dark ? 0.86 : 0.28))
      .frame(width: 36, height: 36)
      .background(Self.hsl(hue, 0.45, dark ? 0.28 : 0.86), in: Circle())
  }

  static func hsl(_ h: Double, _ s: Double, _ l: Double) -> Color {
    let v = l + s * min(l, 1 - l)
    return Color(hue: h, saturation: v == 0 ? 0 : 2 * (1 - l / v), brightness: v)
  }
}

extension ModelCardData {
  /// Which model it is, through which provider.
  var key: String { "\(providerId)/\(modelId)" }
}

extension View {
  /// [bar] over the top of a scrolling page, with the system's scroll edge
  /// under it where there is one, so the page scrolls away beneath it.
  @ViewBuilder func topBar(@ViewBuilder _ bar: () -> some View) -> some View {
    if #available(macOS 26, iOS 26, *) {
      safeAreaBar(edge: .top, spacing: 0, content: bar)
    } else {
      safeAreaInset(edge: .top, spacing: 0) { bar().background(.bar) }
    }
  }
}
