import SwiftUI
import WebKit

/// A web page in the platform's own web view: an artifact served on
/// loopback, a link opened in the app. Where it lands is said back, so the
/// page copies and is titled by where it is now.
struct WebRow: View {
  let model: SettingsModel
  let row: SettingRowData

  var body: some View {
    if let url = row.webUrl.flatMap(URL.init(string:)) {
      WebPage(url: url) { at, title in
        model.say.navigated(id: row.id, url: at.absoluteString, title: title, completion: ignore)
      }
    }
  }
}

/// Each finished load, said with the page's title.
final class WebLandings: NSObject, WKNavigationDelegate {
  var said: (URL, String?) -> Void

  init(said: @escaping (URL, String?) -> Void) { self.said = said }

  func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
    if let url = view.url { said(url, view.title) }
  }
}

#if os(iOS)
  private struct WebPage: UIViewRepresentable {
    let url: URL
    let said: (URL, String?) -> Void

    func makeCoordinator() -> WebLandings { WebLandings(said: said) }

    func makeUIView(context: Context) -> WKWebView {
      let view = WKWebView()
      view.allowsBackForwardNavigationGestures = true
      view.navigationDelegate = context.coordinator
      view.load(URLRequest(url: url))
      return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
      context.coordinator.said = said
      if view.url == nil { view.load(URLRequest(url: url)) }
    }
  }
#else
  private struct WebPage: NSViewRepresentable {
    let url: URL
    let said: (URL, String?) -> Void

    func makeCoordinator() -> WebLandings { WebLandings(said: said) }

    func makeNSView(context: Context) -> WKWebView {
      let view = WKWebView()
      view.allowsBackForwardNavigationGestures = true
      view.navigationDelegate = context.coordinator
      view.load(URLRequest(url: url))
      return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
      context.coordinator.said = said
      if view.url == nil { view.load(URLRequest(url: url)) }
    }
  }
#endif
