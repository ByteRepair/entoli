import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    // Before this returns, or the tap that launched the app reaches no
    // delegate and its chat never opens.
    UNUserNotificationCenter.current().delegate = RemindersPlugin.shared
    return launched
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    VoiceChannel.register(with: engineBridge)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "RemindersPlugin") {
      RemindersPlugin.register(with: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppleFmChannel") {
      AppleFmChannel.register(with: registrar.messenger())
    }
    // The models run in the app's own process here: iOS cannot start one.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MlxChannel") {
      MlxChannel.register(with: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ClipboardChannel") {
      ClipboardChannel.register(with: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BrowserChannel") {
      BrowserChannel.register(with: registrar.messenger())
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
