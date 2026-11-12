import SwiftUI

/// A paired device's own page, reached from its row on the Sync page: the
/// record as this device holds it — the name, the connection, when it was
/// last reached — with the rename beside it, then the two fingerprints a
/// pair exists to compare, and Revoke last. Dart sends the device while the
/// page says it is up, the first before it is pushed; every change comes
/// back as the next one.
struct PairedDevicePage: View {
  var model: SettingsModel
  let id: String

  @State private var renaming = false
  @State private var name = ""
  @State private var revoking = false
  @State private var notice: SettingNoticeData?

  private var shown: SettingsModel.ShownDevice? {
    model.device?.id == id ? model.device : nil
  }

  var body: some View {
    Group {
      if let shown {
        if let device = shown.record {
          form(device)
        } else {
          // Revoked, here or there, while the page was open; or a record
          // that would not read, which is not the same as gone.
          ContentUnavailableView(
            shown.readError == nil ? "No Longer Paired" : "Could Not Read the Device",
            systemImage: shown.readError == nil ? "link" : "exclamationmark.triangle",
            description: shown.readError.map { Text($0) })
        }
      } else {
        ProgressView()
      }
    }
    .navigationTitle("Paired device")
    .onAppear { model.say.deviceShown(id: id, completion: ignore) }
    .onDisappear { model.say.deviceShown(id: nil, completion: ignore) }
    .alert(notice?.message ?? "", isPresented: .present($notice)) {
      Button("OK", role: .cancel) {}
    }
  }

  private func form(_ device: PairedDeviceData) -> some View {
    Form {
      Section {
        // The name as this device files it; names are each side's own, so
        // the rename does not reach the peer.
        LabeledContent {
          Button("Rename…") {
            name = device.name
            renaming = true
          }
        } label: {
          Text(device.name).font(.title3.weight(.semibold))
        }
        LabeledContent {
          connection(device.status)
        } label: {
          Label {
            Text(device.status.word)
            if let error = device.error { Text(error).textSelection(.enabled) }
          } icon: {
            Image(systemName: device.status.symbol).foregroundStyle(device.status.colour)
          }
        }
        LabeledContent("Last connected") { Text(ago(device.lastSeenMs)) }
        if !device.addresses.isEmpty {
          LabeledContent("Last addresses") {
            Text(device.addresses.joined(separator: "\n"))
              .font(.callout.monospaced())
              .multilineTextAlignment(.trailing)
              .textSelection(.enabled)
          }
        }
        LabeledContent("Paired") { Text(ago(device.addedMs)) }
      }
      Section {
        if let fingerprint = device.fingerprint {
          FingerprintRow(value: fingerprint)
        } else {
          Text("The stored key is not a decodable key.").foregroundStyle(.secondary)
        }
      } header: {
        Text("Device fingerprint")
      } footer: {
        Text("The code over \(device.name)'s sync key, as this device received it at the pair.")
      }
      Section {
        FingerprintRow(value: device.ownFingerprint)
      } header: {
        Text("This device")
      } footer: {
        Text(
          "A fingerprint is a code derived from a device's sync key. It is not a secret: it identifies a key and grants nothing. Connecting still requires a pairing code. To verify the pair, compare the Device fingerprint above with the code \(device.name) shows under This device on its own Sync page. Matching codes mean the two devices are still the ones that completed the pairing."
        )
      }
      Section {
        Button("Revoke", role: .destructive) { revoking = true }
      }
    }
    .formStyle(.grouped)
    .alert("Rename \(device.name)", isPresented: $renaming) {
      TextField("Name", text: $name)
      Button("Rename") {
        let next = name.trimmingCharacters(in: .whitespaces)
        if !next.isEmpty && next != device.name { act(.rename, name: next) }
      }
      Button("Cancel", role: .cancel) {}
    }
    .alert("Revoke device?", isPresented: $revoking) {
      Button("Revoke", role: .destructive) { act(.revoke) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Unpair from \(device.name)? They will keep this device until someone revokes there too.")
    }
  }

  /// The connection's action, beside the status it acts on: none while it
  /// waits.
  @ViewBuilder private func connection(_ status: DeviceStatus) -> some View {
    switch status {
    case .connecting: ProgressView().controlSize(.small)
    case .online: Button("Disconnect") { act(.disconnect) }
    case .offline, .error: Button("Connect") { act(.connect) }
    }
  }

  /// [op] on the device; what went wrong is said. A revoke that went
  /// through leaves nothing for this page to show, so it goes.
  private func act(_ op: DeviceOp, name: String? = nil) {
    Task { @MainActor in
      notice = await model.deviceAction(id, op, name: name)
      if op == .revoke && notice == nil { model.back() }
    }
  }

  private func ago(_ ms: Int64) -> String {
    Date(timeIntervalSince1970: Double(ms) / 1000)
      .formatted(.relative(presentation: .named))
  }
}

/// A fingerprint as a row: the grouped code and its copy, one shape for both
/// fingerprints so neither looks like more.
private struct FingerprintRow: View {
  let value: String

  var body: some View {
    LabeledContent {
      Button {
        copyToPasteboard(value)
      } label: {
        Label("Copy Fingerprint", systemImage: "doc.on.doc")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .help("Copy fingerprint")
    } label: {
      Label {
        Text(value).font(.callout.monospaced()).textSelection(.enabled)
      } icon: {
        Image(systemName: "touchid").foregroundStyle(.secondary)
      }
    }
  }
}

extension DeviceStatus {
  var word: String {
    switch self {
    case .online: "Connected"
    case .connecting: "Connecting…"
    case .offline, .error: "Not connected"
    }
  }

  var symbol: String {
    switch self {
    case .online: "circle.fill"
    case .connecting, .offline: "circle"
    case .error: "exclamationmark.circle"
    }
  }

  var colour: Color {
    switch self {
    case .online: .green
    case .connecting: .accentColor
    case .offline: .secondary
    case .error: .red
    }
  }
}
