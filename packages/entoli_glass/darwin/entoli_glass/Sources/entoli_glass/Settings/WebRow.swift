import SwiftUI
import WebKit

/// A web page in the platform's own web view: an artifact served on
/// loopback, a link opened in the app.
struct WebRow: View {
  let row: SettingRowData

  var body: some View {
    if let url = row.webUrl.flatMap(URL.init(string:)) {
      WebPage(url: url)
    }
  }
}

#if os(iOS)
  private struct WebPage: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
      let view = WKWebView()
      view.allowsBackForwardNavigationGestures = true
      view.load(URLRequest(url: url))
      return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
      if view.url == nil { view.load(URLRequest(url: url)) }
    }
  }
#else
  private struct WebPage: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
      let view = WKWebView()
      view.allowsBackForwardNavigationGestures = true
      view.load(URLRequest(url: url))
      return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
      if view.url == nil { view.load(URLRequest(url: url)) }
    }
  }
#endif
