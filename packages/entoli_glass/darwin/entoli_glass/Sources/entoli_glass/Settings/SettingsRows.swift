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
      if row.unsettable {
        ResetMenu(label: nil) { model.say.toggle(id: row.id, on: nil, completion: ignore) }
          .disabled(row.on == nil)
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
    // Unset at a level that inherits, the slider stands where the level
    // above does, and says so.
    case .levels where (row.picked ?? row.inheritedPick) != nil:
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(unsetTitle)
          Spacer()
          reset
        }
        ThinkingBar(
          labels: options.map(\.label), picked: Int(row.picked ?? row.inheritedPick ?? 0)
        ) { i in
          picked.wrappedValue = i
        }
        if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
      }
    case .segmented, .levels:
      VStack(alignment: .leading) {
        HStack {
          Text(unsetTitle)
          Spacer()
          reset
        }
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
        reset
        if let accessory { AccessoryButton(model: model, row: accessory) }
      }
    }
  }

  /// The title, saying where nothing of this level's is picked.
  private var unsetTitle: String {
    row.unsettable && row.picked == nil ? "\(row.title) — Default" : row.title
  }

  /// Back to what unset stands for, on every row of a level that inherits:
  /// dimmed while nothing of this level's is picked.
  @ViewBuilder private var reset: some View {
    if row.unsettable {
      ResetMenu(label: row.inheritedLabel) {
        model.say.pick(id: row.id, option: nil, completion: ignore)
      }
      .disabled(row.picked == nil)
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

  /// Every value it can take: its stops, or each whole number between its
  /// bounds, so one slider steps through either.
  private var stops: [Int64] {
    let given = row.stops.compactMap { $0 }
    if !given.isEmpty { return given }
    let low = row.min ?? 0
    return Array(low...max(row.max ?? low, low))
  }

  private var shown: Int64 { row.value ?? row.inherited ?? 0 }

  var body: some View {
    let stops = stops
    let at = { (index: Double) in stops[min(Int(index.rounded()), stops.count - 1)] }
    VStack(alignment: .leading) {
      HStack {
        Text(row.title)
        Spacer()
        Text("\(dragging.map(at) ?? shown)")
          .monospacedDigit().foregroundStyle(.secondary)
        if row.unsettable {
          ResetMenu(label: row.inherited.map { "\($0)" }) {
            model.say.setNumber(id: row.id, value: nil, completion: ignore)
          }
          .disabled(row.value == nil)
        }
      }
      Slider(
        value: Binding(
          get: { dragging ?? Double(nearest(shown, in: stops)) }, set: { dragging = $0 }),
        in: 0...Double(max(stops.count - 1, 1)), step: 1
      ) { editing in
        if !editing, let value = dragging {
          model.say.setNumber(id: row.id, value: at(value), completion: ignore)
          dragging = nil
        }
      }
    }
  }

  private func nearest(_ value: Int64, in stops: [Int64]) -> Int {
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
      isPresented: .present($editing)
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

/// Something done rather than set, drawn as its hint asks.
struct ActionRow: View {
  let model: SettingsModel
  let row: SettingRowData

  var body: some View {
    if row.hint == .open {
      // Opens another page, which Dart pushes over this one.
      ActionPress(model: model, row: row) {
        HStack {
          if let icon = row.icon {
            Label {
              Titled(title: row.title, detail: row.detail)
            } icon: {
              Image(systemName: icon.symbol)
            }
          } else {
            Titled(title: row.title, detail: row.detail)
          }
          Spacer(minLength: 4)
          if let label = row.label { Text(label).foregroundStyle(.secondary) }
          Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    } else if row.hint == .row || row.hint == .permission {
      HStack {
        if row.hint == .permission, let icon = row.icon {
          Image(systemName: icon.symbol).foregroundStyle(.secondary)
        }
        Titled(title: row.title, detail: row.detail)
        Spacer()
        if row.iconOnly, let icon = row.icon {
          ActionPress(model: model, row: row) {
            Label(row.label ?? row.title, systemImage: icon.symbol).labelStyle(.iconOnly)
          }
          .buttonStyle(.borderless)
          .help(row.label ?? row.title)
        } else {
          ActionPress(model: model, row: row) { Text(row.label ?? row.title) }
        }
      }
    } else {
      ActionPress(model: model, row: row, role: row.destructive ? .destructive : nil) {
        ActionLabel(row: row)
      }
    }
  }
}

/// An action's words, with its icon where it has one.
struct ActionLabel: View {
  let row: SettingRowData

  var body: some View {
    if let icon = row.icon {
      Label(row.label ?? row.title, systemImage: icon.symbol)
    } else {
      Text(row.label ?? row.title)
    }
  }
}

/// A button for [row]'s action: asked first where it asks, said after
/// where it has something to say.
struct ActionPress<Content: View>: View {
  let model: SettingsModel
  let row: SettingRowData
  var role: ButtonRole? = nil
  @ViewBuilder let label: () -> Content
  @State private var confirm: SettingConfirmData?
  @State private var notice: SettingNoticeData?

  var body: some View {
    Button(role: role, action: press, label: label)
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
  let model: SettingsModel
  let row: SettingRowData

  var body: some View {
    let children = model.children(of: row)
    VStack(alignment: .leading, spacing: 8) {
      if row.hint == .buttons {
        HStack {
          ForEach(children, id: \.id) { child in ActionRow(model: model, row: child) }
          if row.busy { ProgressView().controlSize(.small) }
        }
      } else {
        if row.hint != .recommended { Text(row.title).font(.headline) }
        ForEach(children, id: \.id) { child in
          SettingRowView(model: model, row: child)
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

  @ViewBuilder private var field: some View {
    if row.secret {
      SecureField(row.title, text: $typed, prompt: row.prompt.map(Text.init))
    } else {
      TextField(row.title, text: $typed, prompt: row.prompt.map(Text.init))
    }
  }

  var body: some View {
    switch row.hint {
    case .input:
      VStack(alignment: .leading) {
        HStack {
          #if os(iOS)
            // A form's field on iOS shows only its prompt: labelled as
            // Settings labels one, the value trailing.
            LabeledContent {
              field.multilineTextAlignment(.trailing)
            } label: {
              Text(row.title)
            }
          #else
            field
          #endif
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
        // Set from elsewhere — a page's Clear — rather than typed here.
        .onChange(of: row.text) { was, now in
          if row.submitLabel == nil, now != was, (now ?? "") != typed { typed = now ?? "" }
        }
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
          TextEditor(text: $text).editorBox(minHeight: CGFloat(lines) * 22)
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
        PushRow(model: model, to: .text(OpenedText(title: info.title, opens: opens))) {
          infoLabel(info)
        }
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
    "⌘\(alt ? "⌥" : "")\(shift ? "⇧" : "")\(key.uppercased())"
  }
}

/// A page of text to push: what a link names to open.
struct OpenedText: Hashable {
  let title: String
  let opens: TextPageData
}

extension Color {
  /// What a page stands on: the grouped form's own background.
  static var pageBackground: Color {
    #if os(macOS)
      Color(nsColor: .windowBackgroundColor)
    #else
      Color(uiColor: .systemGroupedBackground)
    #endif
  }
}

/// A page of text the app holds: the privacy policy, the licences.
struct TextPage: View {
  let model: SettingsModel
  let title: String
  let opens: TextPageData
  @State private var text: String?

  var body: some View {
    ScrollView {
      Group {
        if let text { DocumentMarkdown(text: text) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
    // Opaque, as a grouped page is: a page sliding in is drawn over the one
    // it covers.
    .background(Color.pageBackground)
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
    HStack {
      PushRow(model: model, to: .models(OpenedModels(row: row.id))) {
        VStack(alignment: .leading, spacing: 2) {
          LabeledContent(row.title, value: row.modelLabel ?? "")
          if let error = row.error {
            Text(error).font(.caption).foregroundStyle(.red)
          } else if let detail = row.detail {
            Text(detail).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      // A level's own pick, back to the one it inherits.
      if row.unsettable {
        ResetMenu(label: row.noneLabel) {
          model.say.setModel(id: row.id, providerId: nil, modelId: nil, completion: ignore)
        }
        .disabled(!row.effective)
      }
    }
  }
}

/// A model picker's page, by the row it picks for.
struct OpenedModels: Hashable {
  let row: String
}

/// A row that opens a page, drawn as a link: pushed through the model, so it
/// is animated on every platform. A button rather than a NavigationLink:
/// links sharing a list row all fire on a tap anywhere in it.
struct PushRow<Label: View>: View {
  let model: SettingsModel
  let to: SettingsRoute
  /// Drawn by the row instead, where something sits between them.
  var chevron = true
  @ViewBuilder let label: Label

  init(
    model: SettingsModel, to: SettingsRoute, chevron: Bool = true,
    @ViewBuilder label: () -> Label
  ) {
    self.model = model
    self.to = to
    self.chevron = chevron
    self.label = label()
  }

  var body: some View {
    Button {
      model.push(to)
    } label: {
      HStack {
        label
        if chevron {
          Spacer(minLength: 4)
          Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

