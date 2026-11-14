import SwiftUI

#if os(iOS)
  import SafariServices
#endif

extension View {
  /// Opens the page in [url] once it is set, and clears it: a CLI's sign-in,
  /// whose callback reaches the program's own `localhost` listener inside
  /// Entoli. On iOS in Safari inside the app, since in Safari itself Entoli
  /// is suspended and the callback reaches nobody; in the browser elsewhere.
  func signInPage(_ url: Binding<URL?>) -> some View {
    modifier(SignInPresenter(url: url))
  }
}

/// Takes down the sign-in page [View.signInPage] opened, where it can.
@MainActor func closeSignInPages() {
  #if os(iOS)
    SafariPage.shown?.dismiss(animated: true)
  #endif
}

private struct SignInPresenter: ViewModifier {
  @Binding var url: URL?
  #if !os(iOS)
    @Environment(\.openURL) private var openURL
  #endif

  func body(content: Content) -> some View {
    content.onChange(of: url) { _, opened in
      guard let opened else { return }
      url = nil
      #if os(iOS)
        SafariPage.present(opened)
      #else
        openURL(opened)
      #endif
    }
  }
}

#if os(iOS)
  /// Presented by UIKit rather than `.sheet`: Safari's own close button
  /// dismisses it behind SwiftUI's back, which then still counts a sheet up
  /// and stalls the sign-in sheet beneath it.
  @MainActor private enum SafariPage {
    static weak var shown: SFSafariViewController?

    static func present(_ url: URL) {
      let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
      guard var top = scene?.keyWindow?.rootViewController else {
        return NSLog("[sign-in] no window to show the page in")
      }
      while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
      let page = SFSafariViewController(url: url)
      shown = page
      top.present(page, animated: true)
    }
  }
#endif
