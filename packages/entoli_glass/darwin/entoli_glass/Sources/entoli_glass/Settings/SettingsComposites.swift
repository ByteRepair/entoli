import CoreImage.CIFilterBuiltins
import PhotosUI
import SwiftUI

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// Items of one kind, each with its own actions, opened in its form and
/// removed on its own; added through the same form.
struct CollectionRow: View {
  let model: SettingsModel
  let row: SettingRowData
  @State private var editing: Editing?
  @State private var confirm: SettingConfirmData?
  /// The item and action [confirm] asks about.
  @State private var pending: (index: Int, action: String)?
  @State private var notice: SettingNoticeData?
  @State private var picking: Int?
  @State private var photo: PhotosPickerItem?

  /// The item a form is open for; nil index for a new one.
  struct Editing: Identifiable {
    let index: Int?
    var id: Int { index ?? -1 }
  }

  var body: some View {
    let items = row.items.compactMap { $0 }
    VStack(alignment: .leading, spacing: 10) {
      if items.isEmpty, let empty = row.emptyItems {
        Text(empty).foregroundStyle(.secondary)
      }
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        if index > 0 { Divider() }
        HStack(alignment: .center) {
          if let bot = item.bot {
            BotFaceView(
              model: model, key: bot, colour: Int(item.botColour ?? 0xff6a1a), size: 32,
              reactToTap: true)
          } else if let data = item.image?.data, let image = PlatformImage(data: data) {
            Image(platformImage: image).resizable().scaledToFill()
              .frame(width: 32, height: 32).clipShape(Circle())
          } else if row.hint == .agents {
            Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(.secondary)
          }
          if let icon = item.icon {
            Image(systemName: icon.symbol).foregroundStyle(item.tone.colour).font(.caption)
          }
          let actions = item.actions.compactMap { $0 }
          let words = VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
            if let subtitle = item.subtitle, !subtitle.isEmpty {
              Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let error = item.error {
              Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
          }
          // An item with a page of its own opens it from its words; the
          // chevron ends the row, after its actions.
          if let opens = item.opens {
            PushRow(
              model: model, to: .text(OpenedText(title: item.title, opens: opens)),
              chevron: false
            ) {
              words.frame(maxWidth: .infinity, alignment: .leading)
            }
          } else if let tap = item.tap, let action = actions.first(where: { $0.id == tap }) {
            // A row that runs an action of its own when tapped: a device's
            // page.
            Button { act(index, action) } label: {
              words.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          } else {
            words
            Spacer()
          }
          if let badge = item.badge {
            Text(badge).font(.caption).foregroundStyle(.secondary)
          }
          if let on = item.on {
            Toggle(
              "", isOn: Binding(get: { on }, set: { _ in run(index, "toggle") })
            ).labelsHidden()
          }
          let editable = row.editable && item.editable
          let pictured = row.takesImages && item.takesImage
          let botted = row.takesBotAvatars && item.takesImage
          if actions.count >= 2 || pictured || botted {
            // One control for the lot, Edit and Remove included, so a row
            // never ends in a strip of buttons.
            Menu {
              if editable {
                Button("Edit") { editing = Editing(index: index) }
              }
              if pictured {
                Button("Choose photo…") { picking = index }
              }
              if botted {
                Button("Bot Avatar…") {
                  model.push(.avatars(OpenedAvatars(agent: item.title, row: row.id, index: index)))
                }
              }
              ForEach(actions, id: \.id) { action in
                Button(action.label, role: action.destructive ? .destructive : nil) {
                  act(index, action)
                }
                .disabled(!action.enabled)
              }
              if row.removable && editable {
                Button(row.removeLabel ?? "Remove", role: .destructive) {
                  model.say.removeItem(id: row.id, index: Int64(index), completion: ignore)
                }
              }
            } label: {
              Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
          } else {
            ForEach(actions, id: \.id) { action in
              Button(action.label, role: action.destructive ? .destructive : nil) {
                act(index, action)
              }
              .buttonStyle(.borderless)
              .disabled(!action.enabled)
            }
            if editable {
              Button("Edit") { editing = Editing(index: index) }.buttonStyle(.borderless)
            }
            if row.removable && editable {
              Button(role: .destructive) {
                model.say.removeItem(id: row.id, index: Int64(index), completion: ignore)
              } label: {
                Image(systemName: "xmark.circle")
              }
              .buttonStyle(.borderless)
              .help(row.removeLabel ?? "Remove")
            }
          }
          if item.opens != nil {
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
        }
      }
      // Borderless, as every control here: a default button in a list row
      // answers a tap anywhere in the row.
      if row.editable, let add = row.addLabel {
        Button(add) { editing = Editing(index: nil) }
          .buttonStyle(.borderless)
          .foregroundStyle(Color.accentColor)
      }
    }
    .sheet(item: $editing) { editing in
      FormSheet(model: model, id: row.id, index: editing.index)
    }
    .photosPicker(
      isPresented: Binding(get: { picking != nil }, set: { if !$0 && photo == nil { picking = nil } }),
      selection: $photo, matching: .images
    )
    .onChange(of: photo) { _, picked in
      guard let picked, let index = picking else { return }
      Task { @MainActor in
        if let data = try? await picked.loadTransferable(type: Data.self),
          let png = PlatformImage(data: data)?.png
        {
          model.say.itemImage(
            id: row.id, index: Int64(index), png: FlutterStandardTypedData(bytes: png),
            completion: ignore)
        }
        photo = nil
        picking = nil
      }
    }
    .asking($confirm, $notice) {
      if let pending { run(pending.index, pending.action) }
    }
  }

  private func act(_ index: Int, _ action: SettingItemActionData) {
    if let ask = action.confirm {
      pending = (index, action.id)
      confirm = ask
    } else {
      // A page the Flutter app opens over the conversation: out of its way.
      if action.handsOff { model.stepAside() }
      run(index, action.id)
    }
  }

  private func run(_ index: Int, _ action: String) {
    Task { @MainActor in notice = await model.itemAction(row.id, index, action) }
  }
}

/// A form Dart makes for an item: asked again after every answer, since a
/// question may come and go with another.
struct FormSheet: View {
  /// The form as [answers] stand, its first for nil.
  let load: ([String?: String?]?) async -> SettingFormData?

  /// Saves it, or says why it could not.
  let save: ([String?: String?]) async -> FormSaveData?

  /// Signs in the program it names; afresh where asked to.
  var signIn: (([String?: String?], Bool) async -> Void)?

  /// Told it was left unsaved.
  var dismissed: (([String?: String?]) -> Void)?

  /// A collection item's form: the item at [index], or a new one.
  init(model: SettingsModel, id: String, index: Int?) {
    load = { await model.form(id, index, $0) }
    save = { await model.submit(id, index, $0) }
    signIn = { await model.formSignIn(id, index, $0, again: $1) }
    dismissed = {
      model.say.formDismissed(
        id: id, index: index.map(Int64.init), answers: $0, completion: ignore)
    }
  }

  init(
    load: @escaping ([String?: String?]?) async -> SettingFormData?,
    save: @escaping ([String?: String?]) async -> FormSaveData?
  ) {
    self.load = load
    self.save = save
  }

  @State private var form: SettingFormData?
  @State private var answers: [String?: String?] = [:]
  /// How many times the form has been asked for, so only the latest answer
  /// is drawn: replies can land out of order.
  @State private var asked = 0
  /// Why the last Save was refused.
  @State private var refused: FormSaveData?
  @State private var saved = false
  @State private var picking: String?
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL

  var body: some View {
    NavigationStack {
      Form {
        if let form {
          ForEach(Array(form.parts.compactMap { $0 }.enumerated()), id: \.offset) { _, part in
            field(part)
          }
          if let problem = form.problem, !problem.isEmpty {
            Text(problem).foregroundStyle(.red)
          }
          if let refused, refused.field == nil { Text(refused.message).foregroundStyle(.red) }
        } else {
          ProgressView()
        }
      }
      .formStyle(.grouped)
      .navigationTitle(form?.title ?? "")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button(refused?.anywayLabel ?? "Save") {
            Task { @MainActor in
              var now = answers
              if let anyway = refused?.anyway { now[anyway] = refused?.yes }
              if let answer = await save(now) {
                refused = answer
              } else {
                saved = true
                dismiss()
              }
            }
          }
          .disabled(!(form?.savable ?? false))
        }
      }
    }
    .frame(minWidth: 460, minHeight: 420)
    .task {
      form = await load(nil)
      answers = form?.answers ?? [:]
    }
    .onDisappear { if !saved { dismissed?(answers) } }
    #if os(macOS)
      .fileImporter(
        isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
        allowedContentTypes: [.item]
      ) { result in
        if let key = picking, case .success(let url) = result {
          binding(key).wrappedValue = url.path
        }
        picking = nil
      }
    #endif
  }

  private func binding(_ key: String) -> Binding<String> {
    Binding(
      get: { (answers[key] ?? nil) ?? "" },
      set: { text in
        answers[key] = text
        if refused?.field == key {
          if let anyway = refused?.anyway { answers[anyway] = nil }
          refused = nil
        }
        asked += 1
        let ask = asked
        let now = answers
        Task { @MainActor in
          let next = await load(now)
          if ask == asked { form = next }
        }
      })
  }

  @ViewBuilder private func field(_ part: FormPartData) -> some View {
    let key = part.id ?? ""
    switch part.kind {
    case .question:
      Text(part.label ?? "").font(.headline).padding(.top, 8)
    case .note:
      Text(part.label ?? "").font(.callout).foregroundStyle(.secondary)
    case .text:
      VStack(alignment: .leading, spacing: 2) {
        if part.lines > 1 {
          Text(part.label ?? "").font(.caption).foregroundStyle(.secondary)
          TextEditor(text: binding(key)).frame(minHeight: CGFloat(part.lines) * 18)
        } else {
          #if os(iOS)
            // An iOS field's label is only its placeholder, gone once filled
            // or where a hint stands in it.
            if part.hint != nil || !binding(key).wrappedValue.isEmpty {
              Text(part.label ?? "").font(.caption).foregroundStyle(.secondary)
            }
          #endif
          HStack {
            if part.secret {
              SecureField(part.label ?? "", text: binding(key), prompt: part.hint.map(Text.init))
            } else {
              TextField(part.label ?? "", text: binding(key), prompt: part.hint.map(Text.init))
            }
            #if os(macOS)
              if part.file { Button("Choose…") { picking = key } }
            #endif
          }
        }
        helper(part)
      }
      .disabled(!part.enabled)
    case .prompt:
      VStack(alignment: .leading, spacing: 2) {
        Text(part.label ?? "").font(.caption).foregroundStyle(.secondary)
        TextEditor(text: binding(key)).frame(minHeight: CGFloat(part.lines) * 18)
        if let hint = part.hint, binding(key).wrappedValue.isEmpty {
          Text(hint).font(.caption).foregroundStyle(.tertiary)
        }
      }
      .disabled(!part.enabled)
    case .choice:
      if part.cards { cards(part) } else { choice(part) }
    case .link:
      if let url = part.url.flatMap(URL.init(string:)) {
        if part.prominent {
          Button { openURL(url) } label: {
            Label(part.label ?? "", systemImage: "arrow.up.forward.square")
          }
          .buttonStyle(.borderedProminent)
        } else {
          Link(part.label ?? "", destination: url)
        }
      }
    case .fold:
      Button {
        binding(key).wrappedValue = part.flipped ?? ""
      } label: {
        Label(part.label ?? "", systemImage: part.on ? "chevron.down" : "chevron.right")
      }
      .buttonStyle(.borderless)
    case .consent:
      VStack(alignment: .leading, spacing: 8) {
        Label(part.label ?? "", systemImage: "hand.raised").font(.headline)
          .foregroundStyle(.red)
        Text(part.message ?? "")
        if let url = part.url.flatMap(URL.init(string:)) {
          Link(part.linkLabel ?? "", destination: url)
        }
        Button(part.accept ?? "", role: .destructive) { binding(key).wrappedValue = part.flipped ?? "" }
      }
    case .entries:
      VStack(alignment: .leading, spacing: 2) {
        Text(part.label ?? "").font(.caption).foregroundStyle(.secondary)
        TextEditor(text: binding(key)).font(.body.monospaced()).frame(minHeight: 70)
        Text(part.hint ?? "").font(.caption).foregroundStyle(.secondary)
        helper(part)
      }
      .disabled(!part.enabled)
    case .signIn:
      HStack {
        Text(part.label ?? "")
        Spacer()
        Button("Sign in…") { Task { @MainActor in await signIn?(answers, false) } }
        Button("Sign in again…") { Task { @MainActor in await signIn?(answers, true) } }
      }
    case .date:
      DatePicker(
        part.label ?? "",
        selection: Binding(
          get: { Self.date((answers[key] ?? nil) ?? "") ?? Date() },
          set: { binding(key).wrappedValue = Self.iso($0) }),
        displayedComponents: [.date, .hourAndMinute]
      )
      .datePickerStyle(.graphical)
      .disabled(!part.enabled)
    case .duration:
      let minutes = Int((answers[key] ?? nil) ?? "") ?? 0
      VStack(alignment: .leading, spacing: 4) {
        Stepper(
          value: Binding(
            get: { minutes },
            set: { binding(key).wrappedValue = "\(max($0, 1))" }),
          in: 1...(60 * 24 * 30), step: minutes < 60 ? 5 : 30
        ) {
          LabeledContent(part.label ?? "", value: Self.spoken(minutes))
        }
        helper(part)
      }
      .disabled(!part.enabled)
    case .multi:
      multi(part)
    }
  }

  @ViewBuilder private func choice(_ part: FormPartData) -> some View {
    let key = part.id ?? ""
    let options = part.options.compactMap { $0 }
    let picked = (answers[key] ?? nil) ?? ""
    VStack(alignment: .leading, spacing: 4) {
      if part.segmented {
        if let label = part.label { Text(label).font(.caption).foregroundStyle(.secondary) }
        Picker(part.label ?? "", selection: binding(key)) {
          ForEach(options, id: \.answer) { o in Text(o.label).tag(o.answer) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      } else {
        Picker(part.label ?? "", selection: binding(key)) {
          ForEach(options, id: \.answer) { o in Text(o.label).tag(o.answer) }
        }
      }
      if let help = options.first(where: { $0.answer == picked })?.help {
        Text(help).font(.caption).foregroundStyle(.secondary)
      }
    }
    .disabled(!part.enabled)
  }

  /// Every option as a row of its own, under its group: what it is, and its
  /// tags.
  @ViewBuilder private func cards(_ part: FormPartData) -> some View {
    let key = part.id ?? ""
    let options = part.options.compactMap { $0 }
    ForEach(Array(options.enumerated()), id: \.offset) { i, option in
      if option.group != (i == 0 ? nil : options[i - 1].group), let group = option.group {
        Text(group).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
          .padding(.top, 6)
      }
      Button {
        binding(key).wrappedValue = option.answer
      } label: {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: option.icon?.symbol ?? "cloud")
            .foregroundStyle(Color.accentColor).frame(width: 28)
          VStack(alignment: .leading, spacing: 4) {
            Text(option.label).font(.headline)
            if let help = option.help {
              Text(help).font(.caption).foregroundStyle(.secondary)
            }
            let tags = option.tags.compactMap { $0 }
            if !tags.isEmpty {
              FlowLayout(spacing: 6, centred: false) {
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                  Text(tag.text).font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(tag.tone.colour.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                }
              }
            }
          }
          Spacer(minLength: 0)
          Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!part.enabled)
    }
  }

  /// The picks are Dart's to work out: each option, and the switch over
  /// all, comes with the answer a tap on it sets.
  @ViewBuilder private func multi(_ part: FormPartData) -> some View {
    let key = part.id ?? ""
    let options = part.options.compactMap { $0 }
    let flip = { (answer: String?) in binding(key).wrappedValue = answer ?? "" }
    VStack(alignment: .leading, spacing: 6) {
      if part.all {
        Toggle(
          part.label ?? "",
          isOn: Binding(get: { part.on }, set: { _ in flip(part.flipped) })
        )
        .font(.headline)
      } else {
        Text(part.label ?? "").font(.caption).foregroundStyle(.secondary)
      }
      if options.contains(where: { $0.help != nil }) {
        // Options that say what they are: a switch each, with its words.
        ForEach(options, id: \.answer) { option in
          Toggle(
            isOn: Binding(get: { option.picked }, set: { _ in flip(option.flipped) })
          ) {
            Titled(title: option.label, detail: option.help)
          }
        }
      } else {
        FlowLayout(spacing: 8, centred: false) {
          ForEach(options, id: \.answer) { option in
            let on = option.picked
            // A plain capsule rather than a glass button: switching a glass
            // button's style rebuilds it, which stalled every tap.
            Button {
              flip(option.flipped)
            } label: {
              Text(option.label).font(.callout).lineLimit(1)
                .foregroundStyle(on ? Color.white : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? Color.accentColor : Color.primary.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .animation(.snappy(duration: 0.15), value: on)
          }
        }
      }
      if let error = part.error { Text(error).font(.caption).foregroundStyle(.red) }
    }
    .disabled(!part.enabled)
  }

  @ViewBuilder private func helper(_ part: FormPartData) -> some View {
    if let refused, let key = part.id, refused.field == key {
      Text(refused.message).font(.caption).foregroundStyle(.red)
    } else if let error = part.error {
      Text(error).font(.caption).foregroundStyle(.red)
    } else if let helper = part.helper {
      Text(helper).font(.caption).foregroundStyle(.secondary)
    }
  }

  /// ISO 8601 local time, the shape Dart's `DateTime.parse` reads back.
  private static let local: DateFormatter = {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return format
  }()

  static func date(_ text: String) -> Date? {
    local.date(from: String(text.prefix(19)))
  }

  static func iso(_ date: Date) -> String { local.string(from: date) }

  static func spoken(_ minutes: Int) -> String {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .full
    formatter.allowedUnits = [.day, .hour, .minute]
    return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
  }
}

/// Things to download, each with the one thing that can be done to it now.
struct CatalogRow: View {
  let model: SettingsModel
  let row: SettingRowData
  @State private var deleting: SettingCatalogData?
  @State private var confirm: SettingConfirmData?
  @State private var notice: SettingNoticeData?

  var body: some View {
    Group {
    ForEach(row.catalog.compactMap { $0 }, id: \.id) { item in
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(item.title)
            if let badge = item.badge {
              Text(badge).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                .overlay(Capsule().stroke(Color.accentColor))
            }
          }
          if let summary = item.summary, !summary.isEmpty {
            Text(summary).font(.caption).foregroundStyle(.secondary)
          }
          let tags = item.tags.compactMap { $0 }
          if !tags.isEmpty {
            Text(tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
          }
          if let note = item.note { Text(note).font(.caption).foregroundStyle(.secondary) }
          if let failure = item.failure { Text(failure).font(.caption).foregroundStyle(.red) }
          if let received = item.received {
            let total = item.total ?? 0
            ProgressView(value: total > 0 ? Double(received) / Double(total) : nil)
            Text(
              item.unpacking
                ? "Unpacking…"
                : ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                  + " of " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
        action(item)
      }
    }
    if let add = row.addLabel {
      Button {
        model.stepAside()
        model.say.catalog(id: row.id, item: "", op: .add, completion: ignore)
      } label: {
        Label(add, systemImage: "link.badge.plus")
      }
    }
    }
    .asking($confirm, $notice) {
      if let deleting { op(deleting, .delete) }
    }
  }

  @ViewBuilder private func action(_ item: SettingCatalogData) -> some View {
    if item.received != nil {
      Button("Cancel") { op(item, .cancel) }.buttonStyle(.borderless)
    } else {
      HStack {
        if item.installed {
          Button(role: .destructive) {
            if let ask = item.deleteConfirm {
              deleting = item
              confirm = ask
            } else {
              op(item, .delete)
            }
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .help("Delete")
        }
        if !item.installed || item.updatable {
          Button(item.installed ? "Update" : "Download") { op(item, .download) }
            .buttonStyle(.borderless)
            .disabled(!item.downloadable)
        }
      }
    }
  }

  private func op(_ item: SettingCatalogData, _ op: CatalogOp) {
    model.say.catalog(id: row.id, item: item.id, op: op, completion: ignore)
  }
}

/// Pairing another device: the window and its code, an invite, or a code
/// from the other device; then the codes both screens show, and the end.
struct PairingRow: View {
  let model: SettingsModel
  let row: SettingRowData
  @State private var code = ""
  @State private var invite: String?
  @State private var answer = ""
  @State private var problem: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Button("Open pairing window") { op(.openWindow) }
          .buttonStyle(.borderedProminent)
        Button("Manual invite") {
          Task { @MainActor in invite = await model.invite(row.id) }
        }
      }
      if row.canScan {
        Button {
          model.stepAside()
          op(.scan)
        } label: {
          Label("Scan QR code", systemImage: "qrcode.viewfinder")
        }
      }
      HStack {
        TextField("Or paste a pairing code", text: $code, prompt: Text("entoli-pair:…"))
        Button("Pair") { join(code) }.disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
    }
    .sheet(isPresented: Binding(get: { row.pairing != nil }, set: { if !$0 { op(.cancel) } })) {
      if let pairing = row.pairing { PairingSheet(pairing: pairing, op: op) }
    }
    .sheet(isPresented: Binding(get: { invite != nil }, set: { if !$0 { invite = nil } })) {
      NavigationStack {
        Form {
          Text("Send this to the other device, then paste its reply below.")
          Text(invite ?? "").font(.caption.monospaced()).textSelection(.enabled)
          TextField("Reply", text: $answer)
        }
        .formStyle(.grouped)
        .navigationTitle("Manual invite")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              invite = nil
              op(.cancel)
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Pair") {
              join(answer)
              invite = nil
            }
          }
        }
      }
      .frame(minWidth: 420, minHeight: 320)
    }
  }

  private func op(_ op: PairingOp) {
    model.say.pairing(id: row.id, op: op, completion: ignore)
  }

  private func join(_ text: String) {
    Task { @MainActor in
      problem = await model.pairWith(row.id, text)
      if problem == nil { code = "" }
    }
  }
}

struct PairingSheet: View {
  let pairing: SettingPairingData
  let op: (PairingOp) -> Void

  var body: some View {
    VStack(spacing: 16) {
      switch pairing.stage {
      case .confirming:
        Text("Do both screens show these codes?").font(.headline)
        Text(pairing.sas ?? "").font(.title.monospaced())
        HStack {
          Button("They don't match", role: .destructive) { op(.mismatch) }
          Button("They match") { op(.match) }.buttonStyle(.borderedProminent)
        }
      case .done:
        Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.green)
        Text(
          pairing.peerName.map { "Device \($0) has been paired." } ?? "The device has been paired."
        )
        .font(.title3)
        Button("Done") { op(.cancel) }
      case .failed:
        Image(systemName: "xmark.octagon").font(.largeTitle).foregroundStyle(.red)
        Text(pairing.error ?? "Pairing failed.").multilineTextAlignment(.center)
        Button("Close") { op(.cancel) }
      case .connecting:
        if let qr = pairing.qr, let image = QRCode.image(qr) {
          image.interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220)
        }
        if let code = pairing.code {
          Text(code).font(.caption.monospaced()).textSelection(.enabled)
        }
        ProgressView("Waiting for the other device…")
        Button("Cancel") { op(.closeWindow) }
      }
    }
    .padding(32)
    .frame(minWidth: 360, minHeight: 360)
  }
}

@MainActor enum QRCode {
  private static let context = CIContext()
  /// The last code drawn: the same one is drawn again on every redraw while
  /// a pairing window is open.
  private static var last: (text: String, image: Image)?

  static func image(_ text: String) -> Image? {
    if let last, last.text == text { return last.image }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    guard let output = filter.outputImage,
      let cg = context.createCGImage(output, from: output.extent)
    else { return nil }
    let image = Image(decorative: cg, scale: 1)
    last = (text, image)
    return image
  }
}

/// Tooling to set up: what stands in its way, the command to run first, the
/// two buttons, the tools found, and the delete.
struct SetupRow: View {
  let model: SettingsModel
  let row: SettingRowData
  @State private var confirm: SettingConfirmData?
  @State private var notice: SettingNoticeData?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let blocked = row.blocked {
        Label(blocked, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
      } else {
        if let notice = row.setupNotice {
          Label(notice, systemImage: "info.circle").foregroundStyle(.secondary)
        }
        if let why = row.prerequisiteWhy, let command = row.prerequisiteCommand {
          Text(why).font(.caption)
          Text(command).font(.caption.monospaced()).textSelection(.enabled)
            .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
        }
        HStack {
          Button(row.setUpLabel ?? "") { op(.setUp) }.buttonStyle(.borderedProminent)
          Button(row.importLabel ?? "") { op(.importTool) }
          if row.running { ProgressView().controlSize(.small) }
        }
        .disabled(row.running)
        if let tools = row.tools {
          ForEach(tools.compactMap { $0 }, id: \.name) { tool in
            LabeledContent(tool.name, value: tool.version ?? "Not installed")
              .foregroundStyle(tool.version == nil ? .red : .primary)
          }
        } else {
          ProgressView().controlSize(.small)
        }
      }
      if let error = row.error { Text(error).font(.caption).foregroundStyle(.red) }
      Button(row.deleteLabel ?? "", role: .destructive) { confirm = row.deleteConfirm }
    }
    .asking($confirm, $notice) { op(.delete) }
  }

  private func op(_ op: SetupOp) {
    model.say.setup(id: row.id, op: op, completion: ignore)
  }
}

#if os(macOS)

  extension NSImage {
    /// As a PNG, the format an agent's picture is kept in.
    var png: Data? {
      guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
        return nil
      }
      return bitmap.representation(using: .png, properties: [:])
    }
  }

  extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
  }
#else

  extension UIImage {
    var png: Data? { pngData() }
  }

  extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
  }
#endif
