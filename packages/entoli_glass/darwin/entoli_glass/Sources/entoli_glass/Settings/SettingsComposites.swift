import CoreImage.CIFilterBuiltins
import SwiftUI

/// Items of one kind, each with its own actions, opened in its form and
/// removed on its own; added through the same form.
struct CollectionRow: View {
  let model: SettingsModel
  let row: SettingRowData
  @State private var editing: Editing?
  @State private var confirm: (SettingConfirmData, Int, String)?
  @State private var notice: SettingNoticeData?

  /// The item a form is open for; nil index for a new one.
  struct Editing: Identifiable {
    let index: Int?
    var id: Int { index ?? -1 }
  }

  var body: some View {
    let items = row.items.compactMap { $0 }
    Group {
      if items.isEmpty, let empty = row.emptyItems {
        Text(empty).foregroundStyle(.secondary)
      }
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        HStack(alignment: .firstTextBaseline) {
          if let icon = item.icon {
            Image(systemName: icon.symbol).foregroundStyle(item.tone.colour).font(.caption)
          }
          VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
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
              "", isOn: Binding(get: { on }, set: { _ in act(index, "toggle", nil) })
            ).labelsHidden()
          }
          ForEach(item.actions.compactMap { $0 }, id: \.id) { action in
            Button(action.label, role: action.destructive ? .destructive : nil) {
              act(index, action.id, action.confirm)
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
      if row.editable, let add = row.addLabel {
        Button(add) { editing = Editing(index: nil) }
      }
    }
    .sheet(item: $editing) { editing in
      FormSheet(model: model, id: row.id, index: editing.index)
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

  private func act(_ index: Int, _ action: String, _ ask: SettingConfirmData?) {
    if let ask { confirm = (ask, index, action) } else { run(index, action) }
  }

  private func run(_ index: Int, _ action: String) {
    Task { @MainActor in notice = await model.itemAction(row.id, index, action) }
  }
}

/// A form Dart makes for an item: asked again after every answer, since a
/// question may come and go with another.
struct FormSheet: View {
  let model: SettingsModel
  let id: String
  let index: Int?
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
              if let notice = await model.submit(id, index, answers) {
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
      form = await model.form(id, index, nil)
      answers = form?.answers ?? [:]
    }
  }

  private func binding(_ key: String) -> Binding<String> {
    Binding(
      get: { (answers[key] ?? nil) ?? "" },
      set: { text in
        answers[key] = text
        Task { @MainActor in form = await model.form(id, index, answers) }
      })
  }

  @ViewBuilder private func field(_ part: FormPartData) -> some View {
    switch part.kind {
    case .question:
      Text(part.label ?? "").font(.headline).padding(.top, 8)
    case .text:
      VStack(alignment: .leading, spacing: 2) {
        if part.lines > 1 {
          Text(part.label ?? "").font(.caption)
          TextEditor(text: binding(part.id ?? "")).frame(minHeight: CGFloat(part.lines) * 18)
        } else {
          TextField(part.label ?? "", text: binding(part.id ?? ""), prompt: part.hint.map(Text.init))
        }
        if let error = part.error {
          Text(error).font(.caption).foregroundStyle(.red)
        } else if let helper = part.helper {
          Text(helper).font(.caption).foregroundStyle(.secondary)
        }
      }
    case .choice:
      let options = part.options.compactMap { $0 }
      let picked = (answers[part.id ?? ""] ?? nil) ?? ""
      VStack(alignment: .leading, spacing: 2) {
        Picker(part.label ?? "", selection: binding(part.id ?? "")) {
          ForEach(options, id: \.answer) { o in Text(o.label).tag(o.answer) }
        }
        if let help = options.first(where: { $0.answer == picked })?.help {
          Text(help).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
}

/// Things to download, each with the one thing that can be done to it now.
struct CatalogRow: View {
  let model: SettingsModel
  let row: SettingRowData
  @State private var deleting: SettingCatalogData?

  var body: some View {
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
