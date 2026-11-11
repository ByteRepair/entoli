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
  @State private var confirm: (SettingConfirmData, Int, String)?
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
          if let data = item.image?.data, let image = PlatformImage(data: data) {
            Image(platformImage: image).resizable().scaledToFill()
              .frame(width: 32, height: 32).clipShape(Circle())
          } else if row.hint == .agents {
            Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(.secondary)
          }
          if let icon = item.icon {
            Image(systemName: icon.symbol).foregroundStyle(item.tone.colour).font(.caption)
          }
          VStack(alignment: .leading, spacing: 2) {
            if let opens = item.opens {
              OpenLink(model: model, title: item.title, opens: opens) { Text(item.title) }
            } else {
              Text(item.title)
            }
            if let subtitle = item.subtitle, !subtitle.isEmpty {
              Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let error = item.error {
              Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
          }
          Spacer()
          if let on = item.on {
            Toggle(
              "", isOn: Binding(get: { on }, set: { _ in run(index, "toggle") })
            ).labelsHidden()
          }
          let actions = item.actions.compactMap { $0 }
          if actions.count > 2 || row.takesImages {
            // One control for the lot, Edit and Remove included, so a row
            // never ends in a strip of buttons.
            Menu {
              if row.editable {
                Button("Edit") { editing = Editing(index: index) }
              }
              if row.takesImages {
                Button("Choose photo…") { picking = index }
              }
              ForEach(actions, id: \.id) { action in
                Button(action.label, role: action.destructive ? .destructive : nil) {
                  act(index, action)
                }
                .disabled(!action.enabled)
              }
              if row.removable && row.editable {
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
            if row.editable {
              Button("Edit") { editing = Editing(index: index) }.buttonStyle(.borderless)
            }
            if row.removable && row.editable {
              Button(role: .destructive) {
                model.say.removeItem(id: row.id, index: Int64(index), completion: ignore)
              } label: {
                Image(systemName: "xmark.circle")
              }
              .buttonStyle(.borderless)
              .help(row.removeLabel ?? "Remove")
            }
          }
        }
      }
      if row.editable, let add = row.addLabel {
        Button(add) { editing = Editing(index: nil) }
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
    .alert(
      confirm?.0.title ?? "",
      isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
      presenting: confirm
    ) { ask in
      Button(ask.0.confirmLabel ?? "OK", role: ask.0.destructive ? .destructive : nil) {
        run(ask.1, ask.2)
      }
      Button("Cancel", role: .cancel) {}
    } message: { ask in
      Text(ask.0.message)
    }
    .alert(
      notice?.message ?? "",
      isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    ) {
      Button("OK", role: .cancel) {}
    }
  }

  private func act(_ index: Int, _ action: SettingItemActionData) {
    if let ask = action.confirm {
      confirm = (ask, index, action.id)
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
  let save: ([String?: String?]) async -> SettingNoticeData?

  /// A collection item's form: the item at [index], or a new one.
  init(model: SettingsModel, id: String, index: Int?) {
    load = { await model.form(id, index, $0) }
    save = { await model.submit(id, index, $0) }
  }

  init(
    load: @escaping ([String?: String?]?) async -> SettingFormData?,
    save: @escaping ([String?: String?]) async -> SettingNoticeData?
  ) {
    self.load = load
    self.save = save
  }

  @State private var form: SettingFormData?
  @State private var answers: [String?: String?] = [:]
  @State private var failed: String?
  @Environment(\.dismiss) private var dismiss

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
          if let failed { Text(failed).foregroundStyle(.red) }
        } else {
          ProgressView()
        }
      }
      .formStyle(.grouped)
      .navigationTitle(form?.title ?? "")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            Task { @MainActor in
              if let notice = await save(answers) {
                failed = notice.message
              } else {
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
  }

  private func binding(_ key: String) -> Binding<String> {
    Binding(
      get: { (answers[key] ?? nil) ?? "" },
      set: { text in
        answers[key] = text
        Task { @MainActor in form = await load(answers) }
      })
  }

  @ViewBuilder private func field(_ part: FormPartData) -> some View {
    let key = part.id ?? ""
    switch part.kind {
    case .question:
      Text(part.label ?? "").font(.headline).padding(.top, 8)
    case .note:
      Text(part.label ?? "").font(.callout).italic().foregroundStyle(.secondary)
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
          TextField(part.label ?? "", text: binding(key), prompt: part.hint.map(Text.init))
        }
        helper(part)
      }
      .disabled(!part.enabled)
    case .choice:
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
    case .list:
      VStack(alignment: .leading, spacing: 2) {
        Text(part.label ?? "").font(.caption).foregroundStyle(.secondary)
        TextEditor(text: binding(key))
          .font(.body.monospaced())
          .frame(minHeight: 70)
        helper(part)
      }
      .disabled(!part.enabled)
    case .multi:
      let picked = Set(((answers[key] ?? nil) ?? "").split(separator: ",").map(String.init))
      VStack(alignment: .leading, spacing: 6) {
        Text(part.label ?? "").font(.caption).foregroundStyle(.secondary)
        Flow(spacing: 8) {
          ForEach(part.options.compactMap { $0 }, id: \.answer) { option in
            let on = picked.contains(option.answer)
            Button {
              var next = picked
              if on { next.remove(option.answer) } else { next.insert(option.answer) }
              binding(key).wrappedValue = next.sorted().joined(separator: ",")
            } label: {
              Text(option.label).font(.callout).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .glassButton(prominent: on)
            .fixedSize()
          }
        }
        if let error = part.error { Text(error).font(.caption).foregroundStyle(.red) }
      }
      .disabled(!part.enabled)
    }
  }

  @ViewBuilder private func helper(_ part: FormPartData) -> some View {
    if let error = part.error {
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
        model.say.catalog(id: row.id, item: "", op: "add", completion: ignore)
      } label: {
        Label(add, systemImage: "link.badge.plus")
      }
    }
    }
    .alert(
      deleting?.deleteConfirm?.title ?? "Delete \(deleting?.title ?? "")?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      presenting: deleting
    ) { item in
      Button("Delete", role: .destructive) { op(item, "delete") }
      Button("Cancel", role: .cancel) {}
    } message: { item in
      Text(item.deleteConfirm?.message ?? "")
    }
  }

  @ViewBuilder private func action(_ item: SettingCatalogData) -> some View {
    if item.received != nil {
      Button("Cancel") { op(item, "cancel") }.buttonStyle(.borderless)
    } else {
      HStack {
        if item.installed {
          Button(role: .destructive) {
            if item.deleteConfirm == nil { op(item, "delete") } else { deleting = item }
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .help("Delete")
        }
        if !item.installed || item.updatable {
          Button(item.installed ? "Update" : "Download") { op(item, "download") }
            .buttonStyle(.borderless)
            .disabled(!item.downloadable)
        }
      }
    }
  }

  private func op(_ item: SettingCatalogData, _ op: String) {
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
        Button("Open pairing window") { op("openWindow") }
          .buttonStyle(.borderedProminent)
        Button("Manual invite") {
          Task { @MainActor in invite = await model.invite(row.id) }
        }
      }
      if row.canScan {
        Button {
          model.stepAside()
          op("scan")
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
    .sheet(isPresented: Binding(get: { row.pairing != nil }, set: { if !$0 { op("cancel") } })) {
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
              op("cancel")
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

  private func op(_ op: String) {
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
  let op: (String) -> Void

  var body: some View {
    VStack(spacing: 16) {
      switch pairing.stage {
      case "confirming":
        Text("Do both screens show these codes?").font(.headline)
        Text(pairing.sas ?? "").font(.title.monospaced())
        HStack {
          Button("They don't match", role: .destructive) { op("mismatch") }
          Button("They match") { op("match") }.buttonStyle(.borderedProminent)
        }
      case "done":
        Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.green)
        Text(
          pairing.peerName.map { "Device \($0) has been paired." } ?? "The device has been paired."
        )
        .font(.title3)
        Button("Done") { op("cancel") }
      case "failed":
        Image(systemName: "xmark.octagon").font(.largeTitle).foregroundStyle(.red)
        Text(pairing.error ?? "Pairing failed.").multilineTextAlignment(.center)
        Button("Close") { op("cancel") }
      default:
        if let qr = pairing.qr, let image = QRCode.image(qr) {
          image.interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220)
        }
        if let code = pairing.code {
          Text(code).font(.caption.monospaced()).textSelection(.enabled)
        }
        ProgressView("Waiting for the other device…")
        Button("Cancel") { op("closeWindow") }
      }
    }
    .padding(32)
    .frame(minWidth: 360, minHeight: 360)
  }
}

enum QRCode {
  static func image(_ text: String) -> Image? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    guard let output = filter.outputImage,
      let cg = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return Image(decorative: cg, scale: 1)
  }
}

/// Tooling to set up: what stands in its way, the command to run first, the
/// two buttons, the tools found, and the delete.
struct SetupRow: View {
  let model: SettingsModel
  let row: SettingRowData
  @State private var deleting = false

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
          Button("Run Setup") { op("setUp") }.buttonStyle(.borderedProminent)
          Button("Import ESBMC") { op("import") }
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
      Button("Delete Byte Repair Data", role: .destructive) { deleting = true }
    }
    .alert(row.label ?? "", isPresented: $deleting) {
      Button("Delete", role: .destructive) { op("delete") }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(row.summary ?? "")
    }
  }

  private func op(_ op: String) {
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

/// Its views in rows, a row wrapping where the next would not fit.
struct Flow: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(subviews, width: proposal.width ?? .infinity)
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for row in arrange(subviews, width: bounds.width) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
    var rows = [Row()]
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
      let needed = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
      if rows[rows.count - 1].width + needed > width, !rows[rows.count - 1].indices.isEmpty {
        rows.append(Row())
      }
      let added = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
      rows[rows.count - 1].indices.append(index)
      rows[rows.count - 1].width += added
      rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
    }
    return rows
  }
}
