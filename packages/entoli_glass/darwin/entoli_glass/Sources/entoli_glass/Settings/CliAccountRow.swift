import SwiftUI

/// A provider form's program account: whether it is signed in, and the one
/// button that fits — Sign in, or Sign in again once it is. A sign-in under
/// way is a sheet over the form.
struct CliAccountRow: View {
  let model: SettingsModel

  var body: some View {
    let account = model.cliAccount
    HStack(spacing: 10) {
      switch account?.step {
      case .signedIn:
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        Text("Signed in to your \(account?.plan ?? "") account")
        Spacer()
        Button("Sign in Again…") { op(.signInAgain) }
      case .signedOut:
        Image(systemName: "person.crop.circle.badge.exclamationmark")
          .foregroundStyle(.secondary)
        Text("Not signed in")
        Spacer()
        Button("Sign In…") { op(.signIn) }.buttonStyle(.borderedProminent)
      case nil, .checking:
        ProgressView().controlSize(.small)
        Text("Checking the sign-in…").foregroundStyle(.secondary)
        Spacer()
      case .installing, .starting, .waiting, .failed:
        ProgressView().controlSize(.small)
        Text("Signing in…").foregroundStyle(.secondary)
        Spacer()
      }
    }
    .sheet(
      isPresented: Binding(
        get: { account?.step.signingIn ?? false },
        set: { if !$0 { op(.cancel) } })
    ) {
      CliSignInSheet(model: model)
    }
  }

  private func op(_ op: CliAccountOp) {
    model.say.cliAccountOp(op: op, completion: ignore)
  }
}

extension CliAccountStep {
  var signingIn: Bool {
    switch self {
    case .installing, .starting, .waiting, .failed: true
    case .checking, .signedIn, .signedOut: false
    }
  }
}

/// A sign-in under way: the program installing, then its page, opened in
/// the browser as soon as the program names it — the user's attention is
/// there, not here — with a field for a code the page may show instead.
private struct CliSignInSheet: View {
  let model: SettingsModel
  @State private var code = ""
  /// The page last opened, so a page named again is opened once.
  @State private var opened: String?
  @Environment(\.openURL) private var openURL

  var body: some View {
    let account = model.cliAccount
    VStack(alignment: .leading, spacing: 16) {
      Text("Sign in to \(account?.plan ?? "")").font(.headline)
      switch account?.step {
      case .installing:
        busy("Installing \(account?.program ?? "")…", value: account?.progress)
      case .waiting:
        if let page = account?.page.flatMap(URL.init(string:)) {
          waiting(page, plan: account?.plan ?? "")
        }
      case .failed:
        Label(account?.failure ?? "The sign-in did not finish.", systemImage: "xmark.octagon")
          .foregroundStyle(.red)
          .textSelection(.enabled)
      default:
        busy("Starting the sign-in…", value: nil)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { op(.cancel) }.keyboardShortcut(.cancelAction)
        if account?.step == .failed {
          Button("Try Again") { op(.signIn) }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(20)
    .frame(width: 420)
    .onChange(of: account?.page, initial: true) { _, page in
      guard let page, page != opened, let url = URL(string: page) else { return }
      opened = page
      openURL(url)
    }
  }

  @ViewBuilder private func busy(_ text: String, value: Double?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(text).foregroundStyle(.secondary)
      if let value { ProgressView(value: value) } else { ProgressView().progressViewStyle(.linear) }
    }
  }

  @ViewBuilder private func waiting(_ page: URL, plan: String) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        ProgressView().controlSize(.small)
        Text("Finish signing in with your \(plan) account in your browser. This carries on by itself once you have.")
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Button("Open the Page Again") { openURL(page) }
        Button("Copy Link") { copyToPasteboard(page.absoluteString) }
      }
      .buttonStyle(.borderless)
      Divider()
      Text("If the page shows a code instead, paste it here.")
        .font(.callout).foregroundStyle(.secondary)
      HStack {
        TextField("Code", text: $code)
          .textFieldStyle(.roundedBorder)
          .onSubmit(send)
        Button("Send", action: send).disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }

  private func send() {
    model.say.cliAccountCode(code: code, completion: ignore)
    code = ""
  }

  private func op(_ op: CliAccountOp) {
    model.say.cliAccountOp(op: op, completion: ignore)
  }
}
