import Flutter
import SwiftUI
import UserNotifications
import entoli_menu

/// The app, as SwiftUI's own template has one: a window whose content is
/// the Flutter view, and the app's menus. The one Flutter engine
/// is the delegate's, started before the window is asked for.
@main
struct EntoliApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    WindowGroup {
      FlutterPane(controller: delegate.flutter)
        .ignoresSafeArea()
        // Scene URLs come to SwiftUI, not to the delegate: handed on, as
        // the plugins listen there (`app_links` for `entoli://`).
        .onOpenURL { url in
          _ = delegate.application(UIApplication.shared, open: url, options: [:])
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
          _ = delegate.application(
            UIApplication.shared, continue: activity, restorationHandler: { _ in })
        }
    }
    .commands { AppCommands() }
  }
}

/// A `FlutterAppDelegate` still, which is how plugins hear the app's events.
final class AppDelegate: FlutterAppDelegate {
  let engine = FlutterEngine(name: "entoli")

  /// The engine's view, the engine running and every plugin and channel on
  /// it, set up the first time anything asks: the window's content or the
  /// launch, whichever SwiftUI gets to first.
  @MainActor private(set) lazy var flutter: FlutterViewController = {
    engine.run()
    GeneratedPluginRegistrant.register(with: engine)
    let messenger = engine.binaryMessenger
    VoiceChannel.register(with: messenger)
    RemindersPlugin.register(with: messenger)
    AppleFmChannel.register(with: messenger)
    // The models run in the app's own process here: iOS cannot start one.
    MlxChannel.register(with: messenger)
    ClipboardChannel.register(with: messenger)
    IntentBridge.shared.register(with: messenger)
    BrowserChannel.register(with: messenger)
    FilesChannel.register(with: messenger)
    ScreenHold.register(with: messenger)
    return FlutterViewController(engine: engine, nibName: nil, bundle: nil)
  }()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    _ = flutter
    // Before this returns, or the tap that launched the app reaches no
    // delegate and its chat never opens.
    UNUserNotificationCenter.current().delegate = RemindersPlugin.shared
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// The Flutter view controller inside SwiftUI. Held by a container rather
/// than handed to SwiftUI: a rebuilt window makes a new container, and the
/// one Flutter controller can have one parent at a time, so each container
/// takes it as it appears.
struct FlutterPane: UIViewControllerRepresentable {
  let controller: UIViewController

  func makeUIViewController(context: Context) -> FlutterContainer {
    FlutterContainer(flutter: controller)
  }

  func updateUIViewController(_ container: FlutterContainer, context: Context) {}
}

final class FlutterContainer: UIViewController {
  private let flutter: UIViewController

  init(flutter: UIViewController) {
    self.flutter = flutter
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("not from a nib") }

  override func loadView() {
    view = UIView()
    // The launch screen's colour until Flutter's first frame, so nothing
    // flashes white in the dark.
    view.backgroundColor = .systemBackground
    flutter.view.backgroundColor = .systemBackground
    adopt()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    adopt()
  }

  /// Moved while on screen without the disappear and appear, Flutter keeps
  /// its old surface and draws no new frame.
  private func adopt() {
    guard flutter.parent !== self else { return }
    let shown = flutter.view.window != nil
    if shown { flutter.beginAppearanceTransition(false, animated: false) }
    flutter.willMove(toParent: nil)
    flutter.view.removeFromSuperview()
    flutter.removeFromParent()
    if shown { flutter.endAppearanceTransition() }
    addChild(flutter)
    flutter.view.frame = view.bounds
    flutter.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(flutter.view)
    flutter.didMove(toParent: self)
    if view.window != nil {
      flutter.beginAppearanceTransition(true, animated: false)
      flutter.endAppearanceTransition()
    }
  }
}

/// Answers `settingUp` on `agent_chat/background`, the channel Android's
/// foreground services answer: iOS gives the app no way to run with the
/// screen locked, so a setup keeps it on. In this file rather than its own so
/// the Xcode project needs no new entry.
enum ScreenHold {
  static func register(with messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "agent_chat/background", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        guard call.method == "settingUp" else { return result(FlutterMethodNotImplemented) }
        UIApplication.shared.isIdleTimerDisabled = (call.arguments as? Bool) ?? false
        result(nil)
      }
  }
}

/// The copy with formatting, which Flutter's own clipboard call cannot make:
/// it writes plain text only. And an image a paste brings, which it cannot
/// read. See rich_clipboard.dart and clipboard_files.dart. In this file rather
/// than its own so the Xcode project needs no new entry.
enum ClipboardChannel {
  private static var channel: FlutterMethodChannel?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "agent_chat/clipboard", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "setHtml":
        guard let args = call.arguments as? [String: Any],
              let plain = args["plain"] as? String, let html = args["html"] as? String
        else { return result(FlutterError(code: "bad-args", message: "plain and html", details: nil)) }
        var item: [String: Any] = ["public.html": html, "public.utf8-plain-text": plain]
        // Pages and Notes read RTF and not HTML, and fall back to the plain
        // entry — which is markdown — without it. RTFD too: it carries a
        // formula's picture, which RTF drops.
        if let text = attributedOf(html) {
          let all = NSRange(location: 0, length: text.length)
          for (type, kind) in [
            ("com.apple.flat-rtfd", NSAttributedString.DocumentType.rtfd),
            ("public.rtf", NSAttributedString.DocumentType.rtf),
          ] {
            item[type] = try? text.data(from: all, documentAttributes: [.documentType: kind])
          }
        }
        UIPasteboard.general.items = [item]
        result(nil)
      case "readFiles":
        let pasteboard = UIPasteboard.general
        // The has- checks raise no paste prompt; reading the image does, so
        // a text paste never asks.
        guard pasteboard.hasImages, !pasteboard.hasStrings,
              let png = pasteboard.data(forPasteboardType: "public.png")
                ?? pasteboard.image?.pngData()
        else { return result([]) }
        result([["bytes": FlutterStandardTypedData(bytes: png)]])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// [html] read by UIKit's own HTML reader — a formula's picture becomes
  /// an attachment — for the RTF a target that reads no HTML keeps. Nil
  /// where it will not read it.
  private static func attributedOf(_ html: String) -> NSAttributedString? {
    guard let data = html.data(using: .utf8) else { return nil }
    return try? NSAttributedString(
      data: data,
      options: [
        .documentType: NSAttributedString.DocumentType.html,
        .characterEncoding: String.Encoding.utf8.rawValue,
      ],
      documentAttributes: nil)
  }
}
