import Flutter
import UIKit
import UserNotifications

/// iOS's half of `ReminderAlarms`: UNUserNotificationCenter, scheduling and
/// notifications alike. There is no process to wake — iOS refuses one — so
/// the system clock's arm is a scheduled notification the OS posts with the
/// process dead, carrying the label and chat id the arm was given: the words
/// and the tap route are fixed at arm time, and the turn itself runs at the
/// next launch's catch-up, a due notification's tap being that launch.
///
/// The call shapes are the macOS plugin's; `calendar`'s names map to
/// DateComponents rather than launchd's entries, and there is no store
/// namespacing — the notification centre is per-app, so one data directory is
/// all one app ever has.
///
/// The errors stay on this side as a `FlutterError` for Dart to log: the
/// clock kind's diff awaits every schedule, and a thrown error there would
/// hold every reload after it.
class RemindersPlugin: NSObject, UNUserNotificationCenterDelegate {
  static let shared = RemindersPlugin()

  /// Called once, from the AppDelegate when the implicit engine is up — the
  /// registrar's messenger is the channel's, and so is the notification
  /// centre's delegate, which no one else has installed.
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "agent_chat/reminders", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      shared.handle(call, result)
    }
    shared.channel = channel
    UNUserNotificationCenter.current().delegate = shared
  }

  private var channel: FlutterMethodChannel?

  /// The chat id a tapped notification carries before Dart's handler was
  /// listening — held for the first drain of `takeOpenChat`, the held-pending
  /// split the Android receive makes of the same launch-by-tap.
  private var pendingOpen: String?

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "schedule": schedule(call, result)
    case "cancel": cancel(call, result)
    case "notify": post(call, result)
    case "notificationsAllowed": notificationsAllowed(result)
    case "requestNotifications": requestNotifications(result)
    case "staleCodes": staleCodes(call, result)
    case "canHoldTurn":
      // A suspended process never claims a fire; the one place a claim could
      // be killed mid-turn is the brief window after backgrounding, where
      // the defer dance hands the fire back instead.
      result(UIApplication.shared.applicationState == .active)
    case "takeOpenChat":
      // The stash is the answer: a tap that launched the process delivered
      // its chat id here before Dart's handler was listening, and the first
      // drain takes it now. The "open" invoke was only the nudge.
      result(pendingOpen)
      pendingOpen = nil
    default: result(FlutterMethodNotImplemented)
    }
  }

  /// The arm: no calendar form counts from now — a one shot or a timer, a
  /// changed time being the next diff's job — and a repeating schedule its
  /// calendar form, wall-clock anchored like launchd's, so what a sleep
  /// swallows coalesces into one delivery on wake where an interval arm is
  /// missed outright. The moment is the notification's; nothing here waits
  /// for the process.
  private func schedule(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let code = (arguments["code"] as? NSNumber)?.intValue,
          let millis = (arguments["at"] as? NSNumber)?.int64Value
    else {
      result(FlutterError(code: "arguments", message: "code and at required", details: nil))
      return
    }
    let at = Date(timeIntervalSince1970: Double(millis) / 1000)
    let content = UNMutableNotificationContent()
    content.title = arguments["label"] as? String ?? "Entoli"
    content.body = "Due now — open to run it."
    content.sound = .default
    // The tap route rides the content the way a completion notification's
    // does; a chatless trigger has none, so its tap is the plain open and
    // the catch-up finds the headless chat the fire makes.
    if let chatId = arguments["chatId"] as? String {
      content.userInfo["chatId"] = chatId
    }
    let trigger: UNNotificationTrigger
    if let calendar = arguments["calendar"] as? String {
      trigger = UNCalendarNotificationTrigger(
        dateMatching: Self.calendarComponents(calendar, at: at), repeats: true)
    } else {
      trigger = UNTimeIntervalNotificationTrigger(
        timeInterval: max(1, at.timeIntervalSinceNow.rounded(.up)), repeats: false)
    }
    let request = UNNotificationRequest(
      identifier: "trigger.\(code)", content: content, trigger: trigger)
    UNUserNotificationCenter.current().add(request) { error in
      DispatchQueue.main.async {
        result(error.map {
          FlutterError(code: "schedule", message: String(describing: $0), details: nil)
        })
      }
    }
  }

  /// The `UNCalendarNotificationTrigger` components of a repeating schedule's
  /// arm, the schedule the macOS plugin maps to launchd's entries: the hourly
  /// its minute, the rest their hour, the weekly its weekday and the monthly
  /// its day. Whatever the source's arithmetic does to later occurrences, the
  /// components only owe the next one — the stamp re-arms. No weekday remap:
  /// DateComponents counts Sunday 1 through Saturday 7 natively.
  static func calendarComponents(_ repeatName: String, at: Date) -> DateComponents {
    let parts = Calendar.current
      .dateComponents([.weekday, .day, .hour, .minute], from: at)
    let hour = parts.hour ?? 0
    let minute = parts.minute ?? 0
    switch repeatName {
    case "daily": return DateComponents(hour: hour, minute: minute)
    case "weekly":
      return DateComponents(hour: hour, minute: minute, weekday: parts.weekday ?? 1)
    case "monthly": return DateComponents(day: parts.day ?? 1, hour: hour, minute: minute)
    default: return DateComponents(minute: minute)
    }
  }

  private func cancel(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let code = (arguments["code"] as? NSNumber)?.intValue
    else {
      result(FlutterError(code: "arguments", message: "code required", details: nil))
      return
    }
    let identifier = "trigger.\(code)"
    UNUserNotificationCenter.current()
      .removePendingNotificationRequests(withIdentifiers: [identifier])
    // A trigger cancelled after its notification was delivered — the prune's
    // case, a trigger deleted while the app was closed — would otherwise sit
    // in the centre saying the trigger is there when its tap runs catch-up
    // to nothing.
    UNUserNotificationCenter.current()
      .removeDeliveredNotifications(withIdentifiers: [identifier])
    result(nil)
  }

  /// The requests the centre still holds that nothing on the clock wants — a
  /// trigger deleted or disabled while the app was closed left one behind,
  /// and only the system's own listing can reach it. The manager cancels each
  /// answer through the ordinary path.
  private func staleCodes(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let wantedRaw = arguments["wanted"] as? [Any]
    else {
      result(FlutterError(code: "arguments", message: "wanted required", details: nil))
      return
    }
    let wanted = Set(wantedRaw.compactMap { ($0 as? NSNumber)?.intValue })
    UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
      let stale = requests.compactMap { request -> Int? in
        let name = request.identifier
        guard name.hasPrefix("trigger."),
              let code = Int(name.dropFirst("trigger.".count))
        else { return nil }
        return wanted.contains(code) ? nil : code
      }
      DispatchQueue.main.async { result(stale) }
    }
  }

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
    UNUserNotificationCenter.current().add(request) { error in
      DispatchQueue.main.async {
        result(error.map {
          FlutterError(code: "notify", message: String(describing: $0), details: nil)
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
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
      granted, _ in
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
  /// it came with.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    notification.request.identifier.hasPrefix("trigger.") ? [] : [.banner, .sound]
  }
}