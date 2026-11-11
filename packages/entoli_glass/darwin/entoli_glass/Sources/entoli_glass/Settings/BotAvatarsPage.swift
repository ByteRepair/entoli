import SwiftUI

/// Where the Bot Avatars page was opened from: an agent's row, to choose
/// one for it, or the agents list, to look through them.
struct OpenedAvatars: Hashable {
  /// The agent choosing, by name; nil to browse.
  let agent: String?

  /// The agents list's row and the agent's place in it, which Use names.
  let row: String
  let index: Int
}

/// The Bot Avatars, as the Flutter editor offers them: the chosen one live
/// over everything — turned by a drag, cheered by a tap, its moods to look
/// at — every preset and import in its own colour to pick from, the palette
/// for the chosen one, and pasted definitions imported. For an agent, Use
/// puts the chosen one on it. What is on offer and what an import makes of
/// its text are the core's.
struct BotAvatarsPage: View {
  let model: SettingsModel
  let opened: OpenedAvatars

  @State private var data: BotAvatarsData?
  @State private var selected: String?
  /// Colours picked this visit, by avatar.
  @State private var colours: [String: Int] = [:]
  @State private var mood = 0
  @State private var tab = 0
  @State private var paste = ""
  @State private var imported: BotImportData?
  @State private var notice: String?
  @Environment(\.dismiss) private var dismiss

  private var entries: [BotAvatarEntryData] { data?.entries.compactMap { $0 } ?? [] }

  private var current: BotAvatarEntryData? {
    entries.first { $0.key == selected } ?? entries.first
  }

  private func colour(of entry: BotAvatarEntryData) -> Int {
    colours[entry.key] ?? Int(entry.colour)
  }

  var body: some View {
    Form {
      if let current {
        Section { stage(current) }
      }
      Section {
        Picker("", selection: $tab) {
          Text("Bots").tag(0)
          Text("Import").tag(1)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        if tab == 0 {
          grid
          if let current { palette(current) }
        } else {
          importer
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(opened.agent == nil ? "Bot Avatars" : "Bot Avatar")
    .toolbar {
      if opened.agent != nil {
        ToolbarItem(placement: .confirmationAction) {
          Button("Use") { use() }.disabled(current == nil)
        }
      }
    }
    .alert(
      notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    ) {
      Button("OK", role: .cancel) {}
    }
    .task { await load() }
  }

  private func stage(_ entry: BotAvatarEntryData) -> some View {
    VStack(spacing: 12) {
      BotFaceView(
        model: model, key: entry.key, colour: colour(of: entry), size: 200, mood: mood,
        turnable: true, reactToTap: true
      )
      .id(entry.key)
      .frame(maxWidth: .infinity)
      .padding(.top, 8)
      Text(entry.name).font(.headline)
      Picker("Mood", selection: $mood) {
        Text("Idle").tag(0)
        Text("Thinking").tag(1)
        Text("Happy").tag(2)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
  }

  private var grid: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
      ForEach(entries, id: \.key) { entry in
        let on = entry.key == current?.key
        Button {
          selected = entry.key
        } label: {
          BotFaceView(
            model: model, key: entry.key, colour: colour(of: entry), size: 52, live: false,
            thumbnail: true
          )
          .padding(6)
          .frame(maxWidth: .infinity)
          .background(
            RoundedRectangle(cornerRadius: 12)
              .fill(on ? Color.accentColor.opacity(0.15) : Color.clear))
          .overlay(
            RoundedRectangle(cornerRadius: 12)
              .strokeBorder(on ? Color.accentColor : Color.clear, lineWidth: 2))
          .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(entry.removable ? "\(entry.name) — yours" : entry.name)
        .accessibilityLabel(entry.name)
        .contextMenu {
          if entry.removable {
            Button("Delete \(entry.name)", role: .destructive) { delete(entry) }
          }
        }
      }
    }
    .padding(.vertical, 4)
  }

  private func palette(_ entry: BotAvatarEntryData) -> some View {
    let picked = colour(of: entry)
    let own = Int(entry.colour)
    let swatches = data?.palette.compactMap { $0 } ?? []
    let custom = !swatches.contains { Int($0.rgb) == picked }
    return Flow(spacing: 8) {
      ForEach(swatches, id: \.rgb) { swatch in
        let rgb = Int(swatch.rgb)
        Button {
          colours[entry.key] = rgb
        } label: {
          Circle()
            .fill(Color(rgb: rgb))
            .frame(width: 28, height: 28)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
            .overlay {
              if rgb == picked {
                Image(systemName: "checkmark")
                  .font(.caption.weight(.bold))
                  .foregroundStyle(rgb == 0xf4f4f4 ? Color.black : Color.white)
              }
            }
        }
        .buttonStyle(.plain)
        .help(rgb == own ? "\(swatch.name) (default)" : swatch.name)
        .accessibilityLabel(swatch.name)
      }
      ColorPicker(
        "Custom colour",
        selection: Binding(
          get: { Color(rgb: picked) },
          set: { if let rgb = $0.rgb { colours[entry.key] = rgb } }),
        supportsOpacity: false
      )
      .labelsHidden()
      .overlay {
        if custom { Circle().strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false) }
      }
      Button {
        colours[entry.key] = nil
      } label: {
        Image(systemName: "arrow.counterclockwise")
      }
      .buttonStyle(.borderless)
      .disabled(picked == own)
      .help("Reset to its own colour")
    }
    .padding(.vertical, 4)
  }

  private var importer: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        "Import new looks using the [Open Bot Avatar](https://dominikscholz.github.io/open-bot-avatar/#/docs) "
          + "spec. Add the bot-avatar-creator skill from the Entoli marketplace to let Entoli "
          + "make one for you."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      TextEditor(text: $paste)
        .font(.callout.monospaced())
        .frame(minHeight: 140)
        .overlay(alignment: .topLeading) {
          if paste.isEmpty {
            Text("{ \"version\": 1, \"id\": \"box\", … }")
              .font(.callout.monospaced())
              .foregroundStyle(.tertiary)
              .padding(.top, 8)
              .padding(.leading, 5)
              .allowsHitTesting(false)
          }
        }
        .onChange(of: paste) { imported = nil }
      HStack {
        Button("Import") { runImport() }
          .glassButton(prominent: true)
          .disabled(paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        PasteButton(payloadType: String.self) { strings in
          if let text = strings.first {
            Task { @MainActor in
              paste = text
              imported = nil
            }
          }
        }
        .labelStyle(.titleAndIcon)
      }
      if let imported {
        ForEach(Array(imported.errors.compactMap { $0 }.enumerated()), id: \.offset) {
          Text($0.element).foregroundStyle(.red)
        }
        ForEach(Array(imported.hints.compactMap { $0 }.enumerated()), id: \.offset) {
          Text("• \($0.element)").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(imported.notes.compactMap { $0 }.enumerated()), id: \.offset) {
          Text($0.element).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func load() async {
    let next: BotAvatarsData? = await withCheckedContinuation { done in
      model.say.botAvatars(agent: opened.agent) { done.resume(returning: try? $0.get()) }
    }
    data = next
    if selected == nil, let next {
      selected = next.selected
      if let key = next.selected, let colour = next.selectedColour {
        colours[key] = Int(colour)
      }
    }
  }

  private func runImport() {
    let text = paste
    Task { @MainActor in
      let result: BotImportData? = await withCheckedContinuation { done in
        model.say.importBotAvatars(text: text) { done.resume(returning: try? $0.get()) }
      }
      imported = result
      guard let result, let added = result.added else { return }
      await load()
      selected = added
      colours[added] = nil
      paste = ""
      imported = nil
      tab = 0
      notice = result.count == 1 ? "Imported." : "Imported \(result.count) avatars."
    }
  }

  private func delete(_ entry: BotAvatarEntryData) {
    if selected == entry.key { selected = nil }
    colours[entry.key] = nil
    Task { @MainActor in
      await withCheckedContinuation { done in
        model.say.deleteBotAvatar(key: entry.key) { _ in done.resume() }
      }
      await load()
    }
  }

  private func use() {
    guard let current else { return }
    let hex = String(colour(of: current), radix: 16)
    Task { @MainActor in
      if let notice = await model.itemAction(
        opened.row, opened.index, "useBot:\(current.key):\(hex)")
      {
        self.notice = notice.message
      } else {
        dismiss()
      }
    }
  }
}

extension Color {
  /// 0xRRGGBB, where the colour resolves to one.
  var rgb: Int? {
    #if os(iOS)
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
    #else
      guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
      let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
    #endif
    func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
    return byte(r) << 16 | byte(g) << 8 | byte(b)
  }
}
