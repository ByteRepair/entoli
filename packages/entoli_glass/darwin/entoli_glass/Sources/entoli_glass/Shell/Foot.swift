import SwiftUI
import UniformTypeIdentifiers

/// The paired device a mirrored chat lives on, as a strip over the
/// conversation: a row of its own, so nothing under it is hidden.
struct DeviceBanner: View {
  let foot: ChatFootSnapshot

  var body: some View {
    if let device = foot.device {
      Label(
        foot.deviceOffline ? "\(device) is offline" : "On \(device)",
        systemImage: foot.deviceOffline ? "wifi.slash" : "laptopcomputer.and.iphone"
      )
      .font(.callout)
      .foregroundStyle(foot.deviceOffline ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(.bar)
    }
  }
}

/// What stands in the composer's place when there is nothing to type into:
/// a project still to be set up, or a paired device that has gone away.
struct FootBarView: View {
  let foot: ChatFootSnapshot
  let say: ChatFootIntents

  var body: some View {
    switch foot.bar {
    case .none:
      EmptyView()
    case .needsSetup:
      HStack(spacing: 10) {
        Label("Setup required before this project can be used.", systemImage: "wrench.and.screwdriver")
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Button("Open Settings") { say.openSetup { _ in } }
      }
      .font(.callout)
      .padding(12)
      .glassSurface(Capsule())
      .padding(8)
    case .offline:
      Label("Offline — showing what this device last had", systemImage: "icloud.slash")
        .font(.callout)
        .foregroundStyle(.red)
        .lineLimit(1)
        .padding(12)
        .glassSurface(Capsule())
        .padding(8)
    }
  }
}

/// What the agent's browser waits on the user for, over the turn surface: a
/// file to upload, a sign-in, or the agent's words for what to do in the
/// page as the button that opens it.
struct BrowserPromptsView: View {
  let foot: ChatFootSnapshot
  let say: ChatFootIntents

  var body: some View {
    VStack(spacing: 8) {
      if let upload = foot.upload {
        UploadPanel(prompt: upload, say: say).id("upload/\(upload.host)/\(upload.multiple)")
      }
      if let credentials = foot.credentials {
        CredentialPanel(prompt: credentials, say: say)
          .id("sign-in/\(credentials.reason)/\(credentials.fields.count)")
      }
      if let hold = foot.hold {
        Button {
          say.watchPage { _ in }
        } label: {
          Label(hold, systemImage: "person.badge.key")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      }
    }
    .padding(.horizontal, 8)
  }
}

/// A file the page asked for, picked with the system's own chooser: the
/// agent is not trusted to pick what leaves the machine.
private struct UploadPanel: View {
  let prompt: UploadPrompt
  let say: ChatFootIntents
  @State private var choosing = false
  @State private var chosen: [URL] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(
          "The agent wants to upload \(prompt.multiple ? "files" : "a file")"
            + (prompt.host.isEmpty ? "" : " to \(prompt.host)"),
          systemImage: "doc.badge.arrow.up"
        )
        .font(.headline)
        Spacer()
        Button("See the page") { say.watchPage { _ in } }.buttonStyle(.borderless)
      }
      Text("You choose what is sent. Sending a message cancels it.")
        .font(.caption)
        .foregroundStyle(.secondary)
      if !chosen.isEmpty {
        Text(chosen.map(\.lastPathComponent).joined(separator: ", ")).font(.callout)
      }
      HStack {
        Spacer()
        Button("Cancel") { say.cancelUpload { _ in } }
        Button(chosen.isEmpty ? "Choose file…" : "Choose again…") { choosing = true }
        Button("Upload") { say.upload(paths: chosen.map(\.path)) { _ in } }
          .buttonStyle(.borderedProminent)
          .disabled(chosen.isEmpty)
      }
    }
    .padding(12)
    .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .fileImporter(
      isPresented: $choosing, allowedContentTypes: [.item],
      allowsMultipleSelection: prompt.multiple
    ) { result in
      if case .success(let urls) = result, !urls.isEmpty { chosen = urls }
    }
  }
}

/// A sign-in the agent asked for. What is typed stays in these fields until
/// it is sent, once, and is typed into the page by the app; the agent never
/// sees it.
private struct CredentialPanel: View {
  let prompt: CredentialPrompt
  let say: ChatFootIntents
  @State private var values: [String]
  @FocusState private var focused: Int?

  init(prompt: CredentialPrompt, say: ChatFootIntents) {
    self.prompt = prompt
    self.say = say
    _values = State(initialValue: Array(repeating: "", count: prompt.fields.count))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(prompt.reason, systemImage: "lock").font(.headline)
        Spacer()
        Button("See the page") { say.watchPage { _ in } }.buttonStyle(.borderless)
      }
      Text("Typed into the page by the app. The agent never sees it.")
        .font(.caption)
        .foregroundStyle(.secondary)
      ForEach(Array(prompt.fields.enumerated()), id: \.offset) { i, field in
        Group {
          if field.secret {
            SecureField(field.label, text: $values[i])
          } else {
            TextField(field.label, text: $values[i])
          }
        }
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .focused($focused, equals: i)
        .onSubmit {
          if i == prompt.fields.count - 1 { submit() } else { focused = i + 1 }
        }
      }
      HStack {
        Spacer()
        Button("Decline") { say.declineCredentials { _ in } }
        Button("Sign in", action: submit).buttonStyle(.borderedProminent)
      }
    }
    .padding(12)
    .glassSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .onAppear { focused = 0 }
  }

  private func submit() {
    say.submitCredentials(values: values) { _ in }
    values = values.map { _ in "" }
  }
}
