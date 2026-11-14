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
  /// the browser elsewhere. On iOS the page closes with this view, which is
  /// to be the view of the waiting step: the program exiting is the one
  /// sure sign the page is done with.
  func signInPage(_ page: Binding<SignInPage?>) -> some View {
    modifier(SignInPresenter(page: page))
  }
}

private struct SignInPresenter: ViewModifier {
  @Binding var page: SignInPage?
  @Environment(\.openURL) private var openURL
  #if os(iOS)
    @State private var shown = ShownPage()
  #endif

  func body(content: Content) -> some View {
    content.onChange(of: page, initial: true) { _, opened in
      guard let opened else { return }
      page = nil
      #if os(iOS)
        shown.present(opened.url)
      #else
        openURL(opened.url)
      #endif
    }
  }
}

#if os(iOS)
  /// Presented by UIKit rather than `.sheet`: Safari's own close button
  /// dismisses it behind SwiftUI's back, which then still counts a sheet up
  /// and stalls the sign-in sheet beneath it.
  private final class ShownPage {
    private weak var controller: UIViewController?

    @MainActor func present(_ url: URL) {
      let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
      guard var top = scene?.keyWindow?.rootViewController else {
        return NSLog("[sign-in] no window to show the page in")
      }
      while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
      let page = SFSafariViewController(url: url)
      controller = page
      top.present(page, animated: true)
    }

    deinit {
      guard let controller else { return }
      DispatchQueue.main.async { controller.dismiss(animated: true) }
    }
  }
#endif
