import SwiftUI

/// A row's subtitle, under its title.
struct Titled: View {
  let title: String
  let detail: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
      if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
    }
  }
}

/// A reset to what unset means, where the level inherits.
struct ResetMenu: View {
  let label: String?
  let reset: () -> Void

  var body: some View {
    Button(action: reset) { Image(systemName: "arrow.uturn.backward") }
      .buttonStyle(.borderless)
      .help(label.map { "Reset to \($0)" } ?? "Reset")
  }
}

struct ToggleRow: View {
  let model: SettingsModel
  let row: SettingRowData

  var body: some View {
    HStack {
      Toggle(
        isOn: Binding(
          get: { row.effective },
          set: { on in model.say.toggle(id: row.id, on: on, completion: ignore) })
      ) {
        Titled(
          title: row.unsettable && row.on == nil
            ? "\(row.title) — Default (\(row.effective ? "on" : "off"))" : row.title,
          detail: row.detail)
      }
      if row.unsettable && row.on != nil {
        ResetMenu(label: nil) { model.say.toggle(id: row.id, on: nil, completion: ignore) }
      }
    }
  }
}

struct ChoiceRow: View {
  let model: SettingsModel
  let row: SettingRowData
  let accessory: SettingRowData?

  private var options: [SettingOptionData] { row.options.compactMap { $0 } }

  /// The picked option's place; -1 for unset, or the named none.
  private var picked: Binding<Int> {
    Binding(
      get: { row.picked.map(Int.init) ?? -1 },
      set: { index in
        model.say.pick(id: row.id, option: index < 0 ? nil : Int64(index), completion: ignore)
      })
  }

  var body: some View {
    switch row.hint {
    case .levels where row.picked != nil:
      VStack(alignment: .leading, spacing: 8) {
        Text(row.title)
        ThinkingBar(labels: options.map(\.label), picked: Int(row.picked ?? 0)) { i in
          picked.wrappedValue = i
        }
        if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
      }
    case .segmented, .levels:
      VStack(alignment: .leading) {
        Text(row.title)
        Picker(row.title, selection: picked) {
          ForEach(Array(options.enumerated()), id: \.offset) { i, o in Text(o.label).tag(i) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
      }
    case .swatches, .corners:
      VStack(alignment: .leading) {
        Text(row.title)
        Looks(options: options, picked: row.picked.map(Int.init)) { i in picked.wrappedValue = i }
      }
    default:
      HStack {
        Picker(selection: picked) {
          if row.unsettable {
            Text(row.inheritedLabel.map { "Default (\($0))" } ?? "Default").tag(-1)
          } else if let none = row.noneLabel {
            Text(none).tag(-1)
          } else if row.picked == nil {
            Text("Nothing picked").tag(-1)
          }
          ForEach(Array(options.enumerated()), id: \.offset) { i, o in
            Text(o.label).tag(i).disabled(!o.enabled)
          }
        } label: {
          Titled(title: row.title, detail: row.error ?? row.detail)
        }
        if let accessory { AccessoryButton(model: model, row: accessory) }
      }
    }
  }
}

/// Options drawn as what they are: swatches and corners.
struct Looks: View {
  let options: [SettingOptionData]
  let picked: Int?
  let pick: (Int) -> Void

  var body: some View {
    // Words want more room than a swatch or a corner does.
    let words = options.contains { $0.argb == nil && $0.radius == nil }
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: words ? 96 : 44), spacing: 10)],
      alignment: .leading, spacing: 10
    ) {
      ForEach(Array(options.enumerated()), id: \.offset) { i, o in
        Button { pick(i) } label: { look(o, selected: i == picked) }
          .buttonStyle(.plain)
          .help(o.detail ?? o.label)
          .disabled(!o.enabled)
      }
    }
  }

  @ViewBuilder private func look(_ o: SettingOptionData, selected: Bool) -> some View {
    let ring = selected ? Color.accentColor : Color.secondary.opacity(0.3)
    if let argb = o.argb {
      ZStack {
        Circle().fill(Color(argb: argb))
        if let second = o.argb2 {
          Circle().fill(Color(argb: second)).mask(
            Rectangle().rotationEffect(.degrees(45)).offset(x: 14, y: 14))
        }
        if selected { Image(systemName: "checkmark").foregroundStyle(.white).font(.caption.bold()) }
      }
      .frame(width: 34, height: 34)
      .overlay(Circle().stroke(ring, lineWidth: selected ? 2 : 1))
    } else if let radius = o.radius {
      RoundedRectangle(cornerRadius: radius / 2)
        .stroke(ring, lineWidth: selected ? 2 : 1)
        .frame(width: 36, height: 36)
        .overlay(Text(o.label).font(.caption2))
    } else {
      Text(o.label)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).stroke(ring, lineWidth: selected ? 2 : 1))
    }
  }
}

extension Color {
  init(argb: Int64) {
    self.init(
      .sRGB,
      red: Double((argb >> 16) & 0xFF) / 255,
      green: Double((argb >> 8) & 0xFF) / 255,
      blue: Double(argb & 0xFF) / 255,
      opacity: Double((argb >> 24) & 0xFF) / 255)
  }
}

/// Several values from one set of options, a slot at a time.
struct SlotsRow: View {
  let model: SettingsModel
  let row: SettingRowData
  @State private var slot = 0

  /// Each group, and where its options start among every group's in order.
  private var groups: [(start: Int, group: SettingGroupData)] {
    var start = 0
    return row.groups.compactMap { $0 }.map { group in
      defer { start += group.options.count }
      return (start, group)
    }
  }

  var body: some View {
    let slots = row.options.compactMap { $0 }
    let pick = row.slotPicks[safe: slot].flatMap { $0 }.map { Int($0) }
    VStack(alignment: .leading, spacing: 10) {
      Text(row.title)
      Picker("Slot", selection: $slot) {
        ForEach(Array(slots.enumerated()), id: \.offset) { i, s in Text(s.label).tag(i) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      ForEach(groups, id: \.start) { start, group in
        Text(group.label).font(.caption).foregroundStyle(.secondary)
        Looks(options: group.options.compactMap { $0 }, picked: pick.map { $0 - start }) { i in
          model.say.pickSlot(
            id: row.id, slot: Int64(slot), option: Int64(start + i), completion: ignore)
        }
      }
    }
  }
}

extension Array {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct RangeRow: View {
  let model: SettingsModel
  let row: SettingRowData
  @State private var dragging: Double?

  private var stops: [Int64] { row.stops.compactMap { $0 } }
  private var shown: Int64 { row.value ?? row.inherited ?? 0 }

  var body: some View {
    VStack(alignment: .leading) {
      HStack {
        Text(row.title)
        Spacer()
        Text("\(dragging.map { Int64($0.rounded()) }.map(label) ?? label(shown))")
          .monospacedDigit().foregroundStyle(.secondary)
        if row.unsettable && row.value != nil {
          ResetMenu(label: row.inherited.map { "\($0)" }) {
            model.say.setNumber(id: row.id, value: nil, completion: ignore)
          }
        }
      }
      if stops.isEmpty {
        let low = Double(row.min ?? 0)
        let high = Double(max(row.max ?? 0, row.min ?? 0) )
        Slider(
          value: Binding(get: { dragging ?? Double(shown) }, set: { dragging = $0 }),
          in: low...max(high, low + 1), step: 1
        ) { editing in
          if !editing, let value = dragging {
            model.say.setNumber(id: row.id, value: Int64(value.rounded()), completion: ignore)
            dragging = nil
          }
        }
      } else {
        Slider(
          value: Binding(
            get: { dragging ?? Double(nearest(shown)) }, set: { dragging = $0 }),
          in: 0...Double(max(stops.count - 1, 1)), step: 1
        ) { editing in
          if !editing, let value = dragging {
            model.say.setNumber(id: row.id, value: stops[Int(value.rounded())], completion: ignore)
            dragging = nil
          }
        }
      }
    }
  }

  private func label(_ value: Int64) -> String {
    stops.isEmpty || dragging == nil ? "\(value)" : "\(stops[Int(value)])"
  }

  private func nearest(_ value: Int64) -> Int {
    stops.indices.min(by: { abs(stops[$0] - value) < abs(stops[$1] - value) }) ?? 0
  }
}

/// A count typed rather than slid to.
struct NumberRow: View {
  let model: SettingsModel
  let row: SettingRowData
  @State private var editing = false
  @State private var typed = ""

  var body: some View {
    HStack {
      LabeledContent(row.title, value: "\(row.value ?? 0)\(row.unit.map { " \($0)" } ?? "")")
      Button("Change") {
        typed = "\(row.value ?? 0)"
        editing = true
      }
      .buttonStyle(.borderless)
      ResetMenu(label: row.inherited.map { "\($0)" }) {
        model.say.setNumber(id: row.id, value: nil, completion: ignore)
      }
    }
    .alert(row.title, isPresented: $editing) {
      TextField(row.prompt ?? row.title, text: $typed)
      Button("Save") {
        if let value = Int64(typed.replacingOccurrences(of: ",", with: "")) {
          model.say.setNumber(id: row.id, value: value, completion: ignore)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      if let prompt = row.prompt { Text(prompt) }
    }
  }
}

struct KeyValuesRow: View {
  let model: SettingsModel
  let row: SettingRowData
  @State private var editing: String??
  @State private var name = ""
  @State private var value = ""

  private var alertTitle: String {
    if case .some(.some(let name)) = editing { return "Edit \(name)" }
    return "Add variable"
  }

  var body: some View {
    let names = row.entries.keys.compactMap { $0 }.sorted()
    ForEach(names, id: \.self) { key in
      HStack {
        Titled(
          title: key,
          detail: row.masked
            ? String(repeating: "•", count: min((row.entries[key] ?? "")?.count ?? 0, 24))
            : (row.entries[key] ?? "") ?? "")
        Spacer()
        Button("Edit") {
          name = key
          value = (row.entries[key] ?? "") ?? ""
          editing = .some(key)
        }
        .buttonStyle(.borderless)
        Button(role: .destructive) {
          model.say.removeEntry(id: row.id, name: key, completion: ignore)
        } label: { Image(systemName: "xmark.circle") }
        .buttonStyle(.borderless)
      }
    }
    Button("Add variable") {
      name = ""
      value = ""
      editing = .some(nil)
    }
    .alert(
      alertTitle,
      isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })
    ) {
      TextField("Name", text: $name)
      TextField("Value", text: $value)
      Button("Save") {
        let replacing = editing ?? nil
        model.say.putEntry(
          id: row.id, name: name, value: value, replacing: replacing, completion: ignore)
      }
      Button("Cancel", role: .cancel) {}
    }
  }
}

/// Something done rather than set: asked first where it asks, said after
/// where it has something to say.
struct ActionRow: View {
  let model: SettingsModel
  let row: SettingRowData
  @State private var confirm: SettingConfirmData?
  @State private var notice: SettingNoticeData?

  var body: some View {
    Group {
      if row.hint == .row || row.hint == .permission {
        HStack {
          if row.hint == .permission, let icon = row.icon {
            Image(systemName: icon.symbol).foregroundStyle(.secondary)
          }
          Titled(title: row.title, detail: row.detail)
          Spacer()
          Button(row.label ?? row.title, action: press)
        }
      } else {
        Button(role: row.destructive ? .destructive : nil, action: press) {
          if let icon = row.icon {
            Label(row.label ?? row.title, systemImage: icon.symbol)
          } else {
            Text(row.label ?? row.title)
          }
        }
      }
    }
    .asking($confirm, $notice) { run() }
  }

  func press() {
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

  func run() {
    Task { @MainActor in notice = await model.run(row.id) }
  }
}

/// An action drawn at the end of another row: hearing a voice.
struct AccessoryButton: View {
  let model: SettingsModel
  let row: SettingRowData

  var body: some View {
    Button {
      Task { @MainActor in _ = await model.run(row.id) }
    } label: {
      Image(systemName: row.icon?.symbol ?? "ellipsis.circle")
    }
    .buttonStyle(.borderless)
    .help(row.label ?? row.title)
    .disabled(!row.enabled)
  }
}

/// Settings under one label: a switch and the count it turns on, or actions
/// side by side.
struct GroupRow: View {
  @ObservedObject var model: SettingsModel
  let row: SettingRowData
  let section: SettingsSectionData

  var body: some View {
    let children = model.children(of: row, in: section)
    VStack(alignment: .leading, spacing: 8) {
      if row.hint == .buttons {
        HStack {
          ForEach(children, id: \.id) { child in ActionRow(model: model, row: child) }
          if row.busy { ProgressView().controlSize(.small) }
        }
      } else {
        if row.hint != .recommended { Text(row.title).font(.headline) }
        ForEach(children, id: \.id) { child in
          SettingRowView(model: model, row: child, section: section)
        }
        if let footnote = row.footnote {
          Text(footnote).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
}

struct TextRow: View {
  let model: SettingsModel
  let row: SettingRowData
  let accessory: SettingRowData?
  @State private var typed = ""
  @State private var editing = false

  var body: some View {
    switch row.hint {
    case .input:
      VStack(alignment: .leading) {
        HStack {
          if row.secret {
            SecureField(row.title, text: $typed, prompt: row.prompt.map(Text.init))
          } else {
            TextField(row.title, text: $typed, prompt: row.prompt.map(Text.init))
          }
          if let submit = row.submitLabel {
            Button(submit) { model.say.setText(id: row.id, text: typed, completion: ignore) }
              .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
          } else if row.clearLabel != nil && !(row.text ?? "").isEmpty {
            ResetMenu(label: row.clearLabel) {
              model.say.setText(id: row.id, text: "", completion: ignore)
            }
          }
        }
        .onAppear { typed = row.submitLabel == nil ? row.text ?? "" : "" }
        .onChange(of: typed) { _, text in
          if row.submitLabel == nil { model.say.setText(id: row.id, text: text, completion: ignore) }
        }
      }
    default:
      HStack {
        Titled(
          title: row.hint == .field ? (row.text?.isEmpty == false ? row.text! : row.emptyLabel ?? "") : row.title,
          detail: row.hint == .field ? row.detail : (row.text?.isEmpty == false ? row.text : row.emptyLabel))
        Spacer()
        Button("Edit") {
          typed = row.text ?? ""
          editing = true
        }
        .buttonStyle(.borderless)
        if let clear = row.clearLabel, !(row.text ?? "").isEmpty {
          Button(clear, role: .destructive) {
            model.say.setText(id: row.id, text: "", completion: ignore)
          }
          .buttonStyle(.borderless)
        }
        if let accessory { AccessoryButton(model: model, row: accessory) }
      }
      .sheet(isPresented: $editing) {
        TextEditSheet(title: row.title, prompt: row.prompt, lines: Int(row.lines), text: typed) { text in
          model.say.setText(id: row.id, text: text, completion: ignore)
        }
      }
    }
  }
}

/// Text typed over one line or several, saved on Save.
struct TextEditSheet: View {
  let title: String
  let prompt: String?
  let lines: Int
  @State var text: String
  let save: (String) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        if lines > 1 {
          TextEditor(text: $text).frame(minHeight: CGFloat(lines) * 22)
        } else {
          TextField(title, text: $text)
        }
        if let prompt { Text(prompt).font(.caption).foregroundStyle(.secondary) }
      }
      .formStyle(.grouped)
      .navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            save(text)
            dismiss()
          }
        }
      }
    }
    .frame(minWidth: 380, minHeight: lines > 1 ? 260 : 140)
  }
}

struct NoticeRow: View {
  let row: SettingRowData

  var body: some View {
    let lines = row.notice.compactMap { $0 }
    switch row.hint {
    case .banner, .card:
      Label {
        Text(lines.map(\.text).joined(separator: "\n"))
      } icon: {
        Image(systemName: row.tone == .good ? "checkmark.shield" : row.icon?.symbol ?? "exclamationmark.triangle")
          .foregroundStyle(row.tone.colour)
      }
    case .field, .installed:
      LabeledContent(row.title, value: lines.map(\.text).joined(separator: "\n"))
    default:
      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          if let url = line.url.flatMap(URL.init(string:)) {
            Link(line.text, destination: url)
          } else {
            Text(line.text).font(.callout).foregroundStyle(.secondary)
          }
        }
      }
    }
  }
}

/// Rows to read: what the app is, the keys that do what.
struct InfoRow: View {
  let model: SettingsModel
  let row: SettingRowData

  var body: some View {
    ForEach(Array(row.info.compactMap { $0 }.enumerated()), id: \.offset) { _, info in
      if let key = info.keyChar {
        LabeledContent(info.title) {
          Text(chord(key, shift: info.keyShift, alt: info.keyAlt))
            .font(.body.monospaced()).foregroundStyle(.secondary)
        }
      } else if let link = info.link.flatMap(URL.init(string:)) {
        Link(destination: link) { infoLabel(info) }
      } else if let opens = info.opens {
        OpenLink(model: model, title: info.title, opens: opens) { infoLabel(info) }
      } else {
        infoLabel(info)
      }
    }
  }

  private func infoLabel(_ info: SettingInfoData) -> some View {
    Label {
      Titled(title: info.title, detail: info.subtitle)
    } icon: {
      Image(systemName: info.icon?.symbol ?? "info.circle")
    }
  }

  private func chord(_ key: String, shift: Bool, alt: Bool) -> String {
    #if os(macOS)
      "⌘\(alt ? "⌥" : "")\(shift ? "⇧" : "")\(key.uppercased())"
    #else
      "⌘\(alt ? "⌥" : "")\(shift ? "⇧" : "")\(key.uppercased())"
    #endif
  }
}

/// A page of text to push: what a link names to open.
struct OpenedText: Hashable {
  let title: String
  let opens: String
}

/// A link to a page of text that answers only for itself. NavigationLinks
/// sharing a list row all fire on a tap anywhere in it, the last one winning.
struct OpenLink<Label: View>: View {
  let model: SettingsModel
  let title: String
  let opens: String
  @ViewBuilder let label: Label

  var body: some View {
    Button {
      model.path.append(OpenedText(title: title, opens: opens))
    } label: {
      HStack {
        label
        Spacer(minLength: 4)
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// A page of text the app holds: the privacy policy, the licences.
struct TextPage: View {
  let model: SettingsModel
  let title: String
  let opens: String
  @State private var text: String?

  var body: some View {
    ScrollView {
      MarkdownBlocks(text: text ?? "")
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
    .navigationTitle(title)
    .task { text = await model.text(of: opens) }
  }
}

/// One model out of every configured provider, picked from a list Dart makes
/// for the role.
struct ModelPickRow: View {
  let model: SettingsModel
  let row: SettingRowData

  var body: some View {
    NavigationLink {
      ModelList(model: model, row: row)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        LabeledContent(row.title, value: row.modelLabel ?? "")
        if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
      }
    }
  }
}

/// Markdown by its blocks — headings, list items, code fences, paragraphs —
/// each block's inline syntax left to AttributedString, which reads no
/// blocks itself.
struct MarkdownBlocks: View {
  let text: String

  private enum Block: Hashable {
    case heading(Int, String)
    case item(Int, String)
    case code(String)
    case paragraph(String)
  }

  private var blocks: [Block] {
    var blocks: [Block] = []
    var paragraph: [String] = []
    var code: [String]?
    func flush() {
      if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
      paragraph = []
    }
    for line in text.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        if let open = code {
          blocks.append(.code(open.joined(separator: "\n")))
          code = nil
        } else {
          flush()
          code = []
        }
      } else if code != nil {
        code!.append(line)
      } else if trimmed.isEmpty {
        flush()
      } else if let hashes = trimmed.firstIndex(where: { $0 != "#" }), hashes != trimmed.startIndex,
        trimmed[hashes] == " "
      {
        flush()
        let level = trimmed.distance(from: trimmed.startIndex, to: hashes)
        blocks.append(.heading(level, String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces)))
      } else if let marker = ["- ", "* ", "+ "].first(where: trimmed.hasPrefix) {
        flush()
        let indent = line.prefix(while: { $0 == " " }).count / 2
        blocks.append(.item(indent, String(trimmed.dropFirst(marker.count))))
      } else {
        paragraph.append(trimmed)
      }
    }
    if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
    flush()
    return blocks
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .heading(let level, let words):
          inline(words).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
            .padding(.top, 4)
        case .item(let indent, let words):
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            inline(words)
          }
          .padding(.leading, CGFloat(indent) * 16)
        case .code(let source):
          ScrollView(.horizontal) {
            Text(source).font(.callout.monospaced()).padding(10)
          }
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case .paragraph(let words):
          inline(words)
        }
      }
    }
  }

  private func inline(_ words: String) -> Text {
    Text(
      (try? AttributedString(
        markdown: words, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(words))
  }
}
