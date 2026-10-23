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
    AppleFmChannel.register(with: engineBridge)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ClipboardChannel") {
      ClipboardChannel.register(with: registrar.messenger())
    }
  }
}

/// The copy with formatting, which Flutter's own clipboard call cannot make:
/// it writes plain text only. See rich_clipboard.dart. In this file rather
/// than its own so the Xcode project needs no new entry.
enum ClipboardChannel {
  private static var channel: FlutterMethodChannel?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "agent_chat/clipboard", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "setHtml" else { return result(FlutterMethodNotImplemented) }
      guard let args = call.arguments as? [String: Any],
            let plain = args["plain"] as? String, let html = args["html"] as? String
      else { return result(FlutterError(code: "bad-args", message: "plain and html", details: nil)) }
      UIPasteboard.general.items = [["public.html": html, "public.utf8-plain-text": plain]]
      result(nil)
    }
    self.channel = channel
  }
}
