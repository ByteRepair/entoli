import Flutter
import UIKit
import UserNotifications

/// iOS's half of `ReminderAlarms`, beside the notification half both Apples
/// share (`macos/Runner/RemindersShared.swift`). There is no process to wake
/// — iOS refuses one — so the system clock's arm is a scheduled notification
/// the OS posts with the process dead, carrying the label and chat id the arm
/// was given: the words and the tap route are fixed at arm time, and the turn
/// itself runs at the next launch's catch-up, a due notification's tap being
/// that launch.
///
/// The call shapes are the macOS plugin's; `calendar`'s names map to
/// DateComponents rather than launchd's entries, and there is no store
/// namespacing — the notification centre is per-app, so one data directory is
/// all one app ever has.
extension RemindersPlugin {
  /// The banner and its sound, where macOS asks for the banner alone.
  static let authorizationOptions: UNAuthorizationOptions = [.alert, .sound]
  static let presentationOptions: UNNotificationPresentationOptions = [.banner, .sound]

  /// iOS keeps this many pending requests and drops the rest without a word.
  private static let pendingLimit = 64

  /// The calls only this platform answers; false for one it does not know.
  func handlePlatform(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) -> Bool {
    switch call.method {
    case "schedule": schedule(call, result)
    case "cancel": cancel(call, result)
    case "staleCodes": staleCodes(call, result)
    case "canHoldTurn":
      // A suspended process never claims a fire; the one place a claim could
      // be killed mid-turn is the brief window after backgrounding, where
      // the defer dance hands the fire back instead.
      result(UIApplication.shared.applicationState == .active)
    default: return false
    }
    return true
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
    // The label is the arm's own name; its nil is the bundle's word for the
    // app rather than a name this file holds.
    content.title = (arguments["label"] as? String)
      ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? ""
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
      identifier: Self.triggerIdentifier(code), content: content, trigger: trigger)
    add(request, errorName: "schedule") { answer in
      result(answer)
      UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
        if requests.count >= Self.pendingLimit {
          NSLog("[reminders] %ld notifications pending, iOS's limit: the latest "
                + "past it are dropped and run only at a launch's catch-up",
                requests.count)
        }
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
    let identifier = Self.triggerIdentifier(code)
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
        guard name.hasPrefix(Self.triggerPrefix),
              let code = Int(name.dropFirst(Self.triggerPrefix.count))
        else { return nil }
        return wanted.contains(code) ? nil : code
      }
      DispatchQueue.main.async { result(stale) }
    }
  }

  /// An arm's identifier: the request code under the arms' namespace, which
  /// the arm write, the cancel, the prune and the present policy all spell
  /// through `triggerPrefix`. A completion post wears `chat.<id>` and nothing
  /// parses it for a code.
  static func triggerIdentifier(_ code: Int) -> String {
    triggerPrefix + "\(code)"
  }
}
