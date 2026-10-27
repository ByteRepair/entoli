import Flutter
import UIKit
import WebKit

// The agent's browser on iOS: one WKWebView per chat, driven from Dart by
// webkit_connection.dart, which speaks the slice of the DevTools Protocol the
// tab sends in terms of these calls. WebKit serves no protocol an app can
// reach. See "On iOS" under "The browser" in lib/data/builtin/AGENTS.md.
final class BrowserChannel: NSObject, WKNavigationDelegate, WKUIDelegate {
  private static var shared: BrowserChannel?

  static func register(with messenger: FlutterBinaryMessenger) {
    shared = BrowserChannel(
      FlutterMethodChannel(name: "agent_chat/browser", binaryMessenger: messenger))
  }

  private let channel: FlutterMethodChannel
  private var views: [String: WKWebView] = [:]
  private var watches: [String: NSKeyValueObservation] = [:]
  // The subframes each page loaded: a challenge's sits in a closed shadow
  // root, where the page script cannot find it.
  private var frames: [String: [String]] = [:]
  private var navigating: [String: FlutterResult] = [:]
  // A window of its own under the app's: visible, so WebKit keeps drawing
  // and running the pages, but covered, and never key — a script's focus
  // counts as a gesture, and in the app's window it brought the keyboard up.
  private var host: UIWindow?
  private var shown: UINavigationController?

  private init(_ channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "start": return result(nil)
    case "close":
      close()
      return result(nil)
    case "clearData":
      let store = WKWebsiteDataStore.default()
      return store.removeData(
        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
      ) { result(nil) }
    case "targets":
      return result(views.keys.map { ["chat": $0, "frames": frames[$0] ?? []] })
    default: break
    }
    guard let chat = args["chat"] as? String else {
      return result(FlutterError(code: "bad-args", message: "chat", details: nil))
    }
    // Suspended, nothing runs: say so rather than time out.
    if UIApplication.shared.applicationState == .background {
      return result(FlutterError(
        code: "background", message: "The browser works only while Entoli is open.",
        details: nil))
    }
    if call.method == "open" {
      open(chat)
      return result(nil)
    }
    guard let view = views[chat] else {
      return result(FlutterError(code: "closed", message: "The page has closed.", details: nil))
    }
    switch call.method {
    case "eval":
      let world: WKContentWorld =
        args["isolated"] as? Bool == true ? .world(name: "entoli") : .page
      view.evaluateJavaScript(args["js"] as? String ?? "", in: nil, in: world) { [weak self] outcome in
        // A script counts as a gesture, so a focus it made takes the
        // keyboard; the page keeps its focus without it.
        if self?.shown == nil { self?.host?.endEditing(true) }
        switch outcome {
        case .success(let value): result(value)
        case .failure(let error as NSError):
          switch WKError.Code(rawValue: error.code) {
          // undefined, or a node: nothing the caller reads.
          case .javaScriptResultTypeIsUnsupported: result(nil)
          case .javaScriptExceptionOccurred:
            result(FlutterError(
              code: "exception",
              message: error.userInfo["WKJavaScriptExceptionMessage"] as? String
                ?? error.localizedDescription,
              details: nil))
          default:
            result(FlutterError(code: "failed", message: error.localizedDescription, details: nil))
          }
        }
      }
    case "navigate":
      guard let url = URL(string: args["url"] as? String ?? "") else {
        return result("That is not an address.")
      }
      navigating.removeValue(forKey: chat)?("Another navigation replaced it.")
      navigating[chat] = result
      view.load(URLRequest(url: url))
    case "history":
      let list = view.backForwardList
      let items = list.backList + [list.currentItem].compactMap { $0 } + list.forwardList
      result(["current": list.backList.count, "urls": items.map { $0.url.absoluteString }])
    case "go":
      let list = view.backForwardList
      if let item = list.item(at: (args["index"] as? Int ?? 0) - list.backList.count) {
        view.go(to: item)
      }
      result(nil)
    case "reload":
      view.reload()
      result(nil)
    case "snapshot":
      snapshot(view, args, result)
    case "show":
      show(view)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // Dart asks only for a page it has lost, so one still here is stale.
  private func open(_ chat: String) {
    remove(chat)
    guard let host = hostView() else { return }
    let view = WKWebView(frame: host.bounds, configuration: WKWebViewConfiguration())
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    // No inset for the status bar: the viewport is the view, as a snapshot's
    // rect takes it.
    view.scrollView.contentInsetAdjustmentBehavior = .never
    view.navigationDelegate = self
    view.uiDelegate = self
    host.addSubview(view)
    views[chat] = view
    // A script's pushState moves the address with no navigation.
    watches[chat] = view.observe(\.url) { [weak self] view, _ in
      if let url = view.url { self?.send("navigated", chat, url.absoluteString) }
    }
  }

  private func hostView() -> UIWindow? {
    if let host { return host }
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
    else { return nil }
    let host = UIWindow(windowScene: scene)
    host.windowLevel = UIWindow.Level(UIWindow.Level.normal.rawValue - 1)
    host.isUserInteractionEnabled = false
    host.isHidden = false
    self.host = host
    return host
  }

  private func remove(_ chat: String) {
    watches.removeValue(forKey: chat)
    frames.removeValue(forKey: chat)
    navigating.removeValue(forKey: chat)?("The page closed.")
    views.removeValue(forKey: chat)?.removeFromSuperview()
  }

  private func close() {
    shown?.dismiss(animated: false)
    shown = nil
    views.keys.forEach(remove)
    host?.isHidden = true
    host = nil
  }

  // The rect is in CSS pixels of the visual viewport; the image is too, at
  // one pixel each, which is what a click takes. A page with no viewport tag
  // is drawn zoomed out, so the view's points are not CSS pixels.
  private func snapshot(_ view: WKWebView, _ args: [String: Any], _ result: @escaping FlutterResult) {
    let size = CGSize(width: args["width"] as? Double ?? 0, height: args["height"] as? Double ?? 0)
    let zoom = view.scrollView.zoomScale
    let config = WKSnapshotConfiguration()
    config.rect = CGRect(
      x: (args["x"] as? Double ?? 0) * zoom, y: (args["y"] as? Double ?? 0) * zoom,
      width: size.width * zoom, height: size.height * zoom)
    let jpeg = args["jpeg"] as? Bool == true
    view.takeSnapshot(with: config) { image, error in
      guard let image else {
        return result(FlutterError(
          code: "failed", message: error?.localizedDescription ?? "No snapshot.", details: nil))
      }
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      let renderer = UIGraphicsImageRenderer(size: size, format: format)
      let draw: (UIGraphicsImageRendererContext) -> Void = { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
      }
      let data = jpeg
        ? renderer.jpegData(withCompressionQuality: 0.7, actions: draw)
        : renderer.pngData(actions: draw)
      result(FlutterStandardTypedData(bytes: data))
    }
  }

  // The real view, where the user's touches are trusted: what a challenge
  // or a passkey needs. Put back under the app when they are done.
  private func show(_ view: WKWebView) {
    guard shown == nil, let host,
      var top = host.windowScene?.windows.first(where: { $0 !== host })?.rootViewController
    else { return NSLog("[browser] no window to show the page in") }
    while let next = top.presentedViewController { top = next }
    let page = UIViewController()
    page.view.backgroundColor = .systemBackground
    page.title = view.title
    view.removeFromSuperview()
    view.frame = page.view.bounds
    view.scrollView.contentInsetAdjustmentBehavior = .automatic
    page.view.addSubview(view)
    page.navigationItem.rightBarButtonItem = UIBarButtonItem(
      systemItem: .done,
      primaryAction: UIAction { [weak self] _ in
        self?.shown?.dismiss(animated: true)
        self?.shown = nil
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.frame = host.bounds
        host.addSubview(view)
      })
    let nav = UINavigationController(rootViewController: page)
    nav.modalPresentationStyle = .fullScreen
    shown = nav
    top.present(nav, animated: true)
  }

  private func chat(of view: WKWebView) -> String? {
    views.first { $0.value === view }?.key
  }

  private func send(_ type: String, _ chat: String, _ url: String? = nil) {
    channel.invokeMethod("event", arguments: ["type": type, "chat": chat, "url": url as Any])
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
    if let chat = chat(of: webView) { send("started", chat) }
  }

  func webView(_ webView: WKWebView, didCommit _: WKNavigation!) {
    guard let chat = chat(of: webView) else { return }
    frames[chat] = []
    navigating.removeValue(forKey: chat)?(nil)
  }

  func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
    if let chat = chat(of: webView) { send("loaded", chat) }
  }

  // Loaded too, or a caller waiting on the load waits out its timeout.
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error
  ) {
    guard let chat = chat(of: webView) else { return }
    navigating.removeValue(forKey: chat)?(error.localizedDescription)
    send("loaded", chat)
  }

  func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
    if let chat = chat(of: webView) { send("loaded", chat) }
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    if let frame = action.targetFrame, !frame.isMainFrame, let chat = chat(of: webView),
      let url = action.request.url?.absoluteString, url.hasPrefix("http")
    {
      frames[chat, default: []].append(url)
    }
    decisionHandler(.allow)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    guard let chat = chat(of: webView) else { return }
    remove(chat)
    send("closed", chat)
  }

  // A link that opens a window opens in this one: there is one page per chat.
  func webView(
    _ webView: WKWebView, createWebViewWith _: WKWebViewConfiguration,
    for action: WKNavigationAction, windowFeatures _: WKWindowFeatures
  ) -> WKWebView? {
    webView.load(action.request)
    return nil
  }
}
