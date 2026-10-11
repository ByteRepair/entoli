import Cocoa
import FlutterMacOS
import UserNotifications
import Darwin

/// macOS's half of `ReminderAlarms`: notifications over
/// `UNUserNotificationCenter`, scheduling over launchd — one job per request
/// code under `~/Library/LaunchAgents/`, each running `open -gj` with a wake
/// argument the Runner hides its window under. The job is also the wake: a
/// fire with the process dead launches the app, the clock kinds' own launch
/// catch-up runs what is due, and a session nobody came to look at quits from
/// `doneFiring`.
///
/// The call shapes are `RemindersChannel.kt`'s, and the errors stay on this
/// side as a `FlutterError` for Dart to log: the clock kind's diff awaits
/// every schedule, and a thrown error there would hold every reload after it.
class RemindersPlugin: NSObject, UNUserNotificationCenterDelegate {
  static let shared = RemindersPlugin()

  /// Called once, from `MainFlutterWindow.awakeFromNib` — the engine's
  /// messenger is ours from there on, and so is the notification centre's
  /// delegate, which no one else has installed.
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
    case "schedule": schedule(call, result)
    case "cancel": cancel(call, result)
    case "notify": post(call, result)
    case "notificationsAllowed": notificationsAllowed(result)
    case "requestNotifications": requestNotifications(result)
    case "staleCodes": staleCodes(call, result)
    case "doneFiring": doneFiring(result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func schedule(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let code = (arguments["code"] as? NSNumber)?.intValue,
          let millis = (arguments["at"] as? NSNumber)?.int64Value
    else {
      result(FlutterError(code: "arguments", message: "code and at required", details: nil))
      return
    }
    do {
      try writeJob(code: code, at: Date(timeIntervalSince1970: Double(millis) / 1000))
      result(nil)
    } catch {
      result(FlutterError(code: "schedule", message: String(describing: error), details: nil))
    }
  }

  /// launchd does not re-read a loaded plist, so a changed interval is
  /// bootout, rewrite, bootstrap. A bootout of a job never loaded reports
  /// failure; only the bootstrap after is a failure worth saying.
  private func writeJob(code: Int, at: Date) throws {
    let label = Self.jobLabel(code: code)
    _ = try? runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
    let plist = Self.agentDirectory().appendingPathComponent("\(label).plist")
    try Self.agentDirectory().ensureDirectory()
    let content: [String: Any] = [
      "Label": label,
      "ProgramArguments": [
        "/usr/bin/open",
        "-gj",
        Bundle.main.bundlePath,
        "--args",
        "entoli-wake",
      ],
      // No one-shot calendar form exists here, so the moment is an interval
      // counted from the load — which is what the rewrite re-dates.
      "StartInterval": max(1, Int(at.timeIntervalSinceNow.rounded(.up))),
    ]
    guard (content as NSDictionary).write(toFile: plist.path, atomically: true) else {
      throw MessageError("plist not written to \(plist.path)")
    }
    try runLaunchctl(["bootstrap", "gui/\(getuid())", plist.path])
  }

  private func cancel(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let code = (arguments["code"] as? NSNumber)?.intValue
    else {
      result(FlutterError(code: "arguments", message: "code required", details: nil))
      return
    }
    let label = Self.jobLabel(code: code)
    // A job that was loaded gets booted; that a never-loaded one's bootout
    // reports failure is the usual answer, not news. The plist is what has to
    // be gone — a job loaded without its file is launchd's to error on, and
    // the next schedule rewrites both halves of it.
    _ = try? runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
    do {
      try FileManager.default.removeItem(at: Self.agentDirectory().appendingPathComponent("\(label).plist"))
    } catch let error as NSError where error.code == NSFileNoSuchFileError {
      // A plist that was never there is not a failure to say.
    } catch {
      result(FlutterError(code: "cancel", message: String(describing: error), details: nil))
      return
    }
    result(nil)
  }

  /// The jobs launchd still holds that nothing on the clock wants — a trigger
  /// deleted or disabled while the app was closed left its plist behind, and
  /// without the prune below it would keep waking the app on the old
  /// schedule. The plist's name is the code; the clock kind does the
  /// cancelling through the channel.
  private func staleCodes(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let wanted = Set(
      ((call.arguments as? [String: Any])?["wanted"] as? [Any])?
        .compactMap { ($0 as? NSNumber)?.intValue } ?? [])
    let listed = (try? FileManager.default.contentsOfDirectory(
      at: Self.agentDirectory(), includingPropertiesForKeys: nil)) ?? []
    let stale = listed.compactMap { url -> Int? in
      guard url.pathExtension == "plist" else { return nil }
      let name = url.deletingPathExtension().lastPathComponent
      guard name.hasPrefix(Self.jobPrefix) else { return nil }
      guard let code = Int(name.dropFirst(Self.jobPrefix.count)) else { return nil }
      return wanted.contains(code) ? nil : code
    }
    result(stale)
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
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) {
      granted, _ in
      DispatchQueue.main.async { result(granted) }
    }
  }

  /// A wake session's work has drained; a launch nobody came to look at stops
  /// being an app and quits, the next fire's job being launchd's. The short
  /// delay lets the reply reach Dart before the process goes. A session
  /// someone activated keeps living, from there an ordinary one.
  private func doneFiring(_ result: @escaping FlutterResult) {
    if AppDelegate.wake && !AppDelegate.userShowedUp {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        NSApp.terminate(nil)
      }
    }
    result(nil)
  }

  /// A tapped notification takes its chat id back through the channel —
  /// held for `takeOpenChat` and nudged, the two routes in. The delegate
  /// methods below call this.
  func open(chatId: String) {
    pendingOpen = chatId
    channel?.invokeMethod("open", arguments: chatId)
  }

  /// The half the label is namespaced under: a debug build runs against its
  /// own data directory (`agent-chat-debug`), so its jobs must never share
  /// launchd's namespace with an installed copy's, where its prune would
  /// mistake the other's jobs for orphans.
  #if DEBUG
  static let flavour = "debug"
  #else
  static let flavour = "release"
  #endif

  static var jobPrefix: String {
    "\(Bundle.main.bundleIdentifier ?? "entoli").\(flavour).trigger."
  }

  /// The label carries this launch's bundle identifier, so a debug build's
  /// jobs never argue with an installed copy's over one namespace.
  static func jobLabel(code: Int) -> String {
    "\(jobPrefix)\(code)"
  }

  /// The user's launch agents: an unsandboxed app may write there, and the
  /// user session's launchd (`gui/<uid>`) boots from it asking nothing.
  static func agentDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
  }

  /// One launchctl call, its stderr in the error it answers when it failed.
  /// Reading stderr to the end before waiting on the exit is the order that
  /// cannot deadlock a pipe.
  func runLaunchctl(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    let output = String(
      decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw MessageError(
        "launchctl \(arguments.first ?? "") exited \(process.terminationStatus): \(output)")
    }
  }

  /// The frontmost app is shown the banner it would otherwise swallow, the
  /// way Android's always-posted notification reads; a hidden wake session is
  /// a background app and is never asked.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner]
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
}

extension URL {
  /// `~/Library/LaunchAgents` does not exist until something first writes one.
  func ensureDirectory() throws {
    if !FileManager.default.fileExists(atPath: path) {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
  }
}

/// The error the launchctl half answers with; its message is all the Dart log
/// ever sees of a refused boot.
struct MessageError: Error, CustomStringConvertible {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var description: String {
    message
  }
}