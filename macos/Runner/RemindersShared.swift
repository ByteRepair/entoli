#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif
import Foundation
import UserNotifications

/// The half of the `agent_chat/reminders` channel both Apples answer the same
/// way: the notification centre — posting, its permission, the tap route —
/// and the dispatch. Compiled into both Runners (the iOS project references
/// this file here); what differs per platform is in each Runner's
/// `RemindersPlugin.swift`, an extension answering `handlePlatform`: the arm
/// itself, which is a launchd job on macOS and a scheduled notification on
/// iOS, its cancel and prune, and the two answers only one platform has.
///
/// The call shapes are `RemindersChannel.kt`'s, and the errors stay on this
/// side as a `FlutterError` for Dart to log: the clock kind's diff awaits
/// every schedule, and a thrown error there would hold every reload after it.
class RemindersPlugin: NSObject, UNUserNotificationCenterDelegate {
  static let shared = RemindersPlugin()

  /// Called once, when the engine is up — the messenger is the channel's.
  /// The notification centre's delegate is installed here too, and earlier
  /// where the platform's launch needs it to be (iOS's AppDelegate).
  static func register(with binaryMessenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "agent_chat/reminders", binaryMessenger: binaryMessenger)
    channel.setMethodCallHandler { call, result in
      shared.handle(call, result)
    }
    shared.channel = channel
    UNUserNotificationCenter.current().delegate = shared
  }

  private var channel: FlutterMethodChannel?

  /// The chat id a tapped notification carries before Dart's handler was
  /// listening — held for the first drain of `takeOpenChat`, the
  /// held-pending split the Android receive makes of the same launch-by-tap.
  private var pendingOpen: String?

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "notify": post(call, result)
    case "notificationsAllowed": notificationsAllowed(result)
    case "requestNotifications": requestNotifications(result)
    case "takeOpenChat":
      // The stash is the answer: a tap that launched the process delivered
      // its chat id here before Dart's handler was listening, and the first
      // drain takes it now. The "open" invoke was only the nudge.
      result(pendingOpen)
      pendingOpen = nil
    default:
      if !handlePlatform(call, result) { result(FlutterMethodNotImplemented) }
    }
  }

  /// The arms' namespace on iOS, where an arm is a notification request: a
  /// due arm's banner is not presented over a running app. No macOS request
  /// wears it — an arm there is a launchd job — so the check is a no-op there.
  static let triggerPrefix = "trigger."

  private func post(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let title = arguments["title"] as? String,
          let body = arguments["body"] as? String
    else {
      result(FlutterError(code: "arguments", message: "title and body required", details: nil))
      return
    }
    let chatId = arguments["chatId"] as? String
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    // The identifier named after the chat is the tap route and the replace at
    // once: a repost rewrites the one notification rather than piling up
    // beside it, and a tap carries the id back through [open].
    let identifier: String
    if let chatId {
      content.userInfo["chatId"] = chatId
      identifier = "chat.\(chatId)"
    } else {
      identifier = UUID().uuidString
    }
    // Trigger nil is delivered immediately; nothing here waits.
    let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    add(request, errorName: "notify", then: result)
  }

  /// One completion hop for every request this plugin adds: the error stays
  /// on this side as a `FlutterError` for Dart to log.
  func add(_ request: UNNotificationRequest, errorName: String,
           then result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().add(request) { error in
      DispatchQueue.main.async {
        result(error.map {
          FlutterError(code: errorName, message: String(describing: $0), details: nil)
        })
      }
    }
  }

  private func notificationsAllowed(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      DispatchQueue.main.async {
        result(settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional)
      }
    }
  }

  private func requestNotifications(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(
      options: Self.authorizationOptions
    ) { granted, _ in
      DispatchQueue.main.async { result(granted) }
    }
  }

  /// A tapped notification takes its chat id back through the channel —
  /// held for `takeOpenChat` and nudged, the two routes in. A due arm's and
  /// a completion's both name their chat in userInfo.
  func open(chatId: String) {
    pendingOpen = chatId
    channel?.invokeMethod("open", arguments: chatId)
  }

  // The delegate's async methods are called off the main thread; `open`
  // touches the channel and the stash, which are the main thread's.
  @MainActor
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    // A tap is the default action; a dismiss is not an opening and says
    // nothing the chat wants.
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
      return
    }
    guard let chatId = response.notification.request.content.userInfo["chatId"] as? String
    else {
      return
    }
    open(chatId: chatId)
  }

  /// The frontmost app is shown the completion banner it would otherwise
  /// swallow, the way Android's always-posted notification reads — but not
  /// a due arm's: when the process is here, its own clock runs that fire a
  /// moment behind the system's, so the banner would arrive beside the run
  /// it came with. A hidden macOS wake session is a background app and is
  /// never asked.
  @MainActor
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    notification.request.identifier.hasPrefix(Self.triggerPrefix)
      ? [] : Self.presentationOptions
  }
}
