import SwiftUI

#if os(iOS)
  import SafariServices
#endif

/// A CLI's sign-in page, whose callback reaches the program's own
/// `localhost` listener inside Entoli.
struct SignInPage: Identifiable, Equatable {
  let url: URL
  var id: URL { url }
}

extension View {
  /// Opens [page] once it is set: on iOS in Safari inside the app, since in
  /// Safari itself Entoli is suspended and the callback reaches nobody; in
  /// the browser elsewhere.
  func signInPage(_ page: Binding<SignInPage?>) -> some View {
    modifier(SignInPresenter(page: page))
  }
}

private struct SignInPresenter: ViewModifier {
  @Binding var page: SignInPage?
  @Environment(\.openURL) private var openURL

  func body(content: Content) -> some View {
    #if os(iOS)
      content.sheet(item: $page) { SafariView(url: $0.url).ignoresSafeArea() }
    #else
      content.onChange(of: page) { _, opened in
        guard let opened else { return }
        page = nil
        openURL(opened.url)
      }
    #endif
  }
}

#if os(iOS)
  private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
      SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
  }
#endif
