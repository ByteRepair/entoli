import BackgroundTasks
import Flutter
import UIKit

/// Answers `agent_chat/background`, the channel Android's foreground services
/// answer: while a turn, a setup, a download, a backup, a sign-in or a sync
/// connection is held, one continued-processing task keeps the app running
/// off screen, and the system shows it as a Live Activity with its own stop.
/// See "Running off screen" in ios/AGENTS.md.
enum WorkHold {
  private static let taskPrefix = "io.byterepair.entoli.work"
  private static let title = "Entoli"

  private static var turns = 0
  private static var settingUp = false
  private static var download: (label: String, received: Int64, total: Int64)?
  private static var syncNames: [String]?
  private static var signInPlan: String?
  private static var backingUp = false

  private static var task: BGContinuedProcessingTask?
  /// Submitted, its launch handler not yet run.
  private static var pending = false
  private static var heartbeat: Timer?
  private static var channel: FlutterMethodChannel?

  private static var busy: Bool {
    turns > 0 || settingUp || download != nil || syncNames != nil || signInPlan != nil
      || backingUp
  }

  /// Each held job in the words Android's notification uses for it, worded
  /// here rather than in Dart since the port carries counts and labels.
  private static var summary: String {
    var parts: [String] = []
    if turns == 1 { parts.append("Running a turn") }
    if turns > 1 { parts.append("Running \(turns) turns") }
    if settingUp { parts.append("Setting up tools") }
    if let download {
      let percent = download.total > 0 ? " (\(download.received * 100 / download.total)%)" : ""
      parts.append("Downloading \(download.label)\(percent)")
    }
    if backingUp { parts.append("Backing up") }
    if let plan = signInPlan { parts.append("Waiting for you to sign in to \(plan)") }
    if let names = syncNames {
      parts.append(names.count == 1 ? "Connected to \(names[0])" : "\(names.count) devices connected")
    }
    return parts.joined(separator: " · ")
  }

  static func register(with messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "agent_chat/background", binaryMessenger: messenger)
    channel?.setMethodCallHandler(handle)
    // Refused from the background: work that began there, or a task the
    // system expired, is held again once the app is in front.
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in if busy { update() } }
  }

  private static func handle(_ call: FlutterMethodCall, _ result: FlutterResult) {
    switch call.method {
    case "running": turns = (call.arguments as? NSNumber)?.intValue ?? 0
    case "settingUp": settingUp = (call.arguments as? Bool) ?? false
    case "downloading":
      download = (call.arguments as? [String: Any]).map {
        (
          label: $0["label"] as? String ?? "a model",
          received: ($0["received"] as? NSNumber)?.int64Value ?? 0,
          total: ($0["total"] as? NSNumber)?.int64Value ?? 0
        )
      }
    case "syncing":
      syncNames = (call.arguments as? [String: Any]).map { $0["names"] as? [String] ?? [] }
    case "signingIn": signInPlan = call.arguments as? String
    case "backingUp": backingUp = (call.arguments as? Bool) ?? false
    // Not held: the prefill is MLX's, and iOS gives the GPU only to the app
    // in front, so off screen it would fail rather than finish.
    default: return result(FlutterMethodNotImplemented)
    }
    update()
    result(nil)
  }

  private static func update() {
    guard busy else { return finish() }
    if task == nil && !pending { submit() }
    task?.updateTitle(title, subtitle: summary)
  }

  private static func submit() {
    let identifier = "\(taskPrefix).\(UUID().uuidString)"
    // The wildcard is Info.plist's alone: a handler registers under the
    // concrete id, and a submit with none raises an exception `try` cannot
    // catch. Each id is fresh, since registering one twice kills the app.
    guard BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main, launchHandler: {
      begin($0 as! BGContinuedProcessingTask)
    }) else {
      return NSLog("[background] the continued task's handler was refused")
    }
    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier, title: title, subtitle: summary)
    // Queued, the task would say the work is waiting while it already runs.
    request.strategy = .fail
    do {
      try BGTaskScheduler.shared.submit(request)
      pending = true
    } catch {
      NSLog("[background] the continued task was refused: %@", "\(error)")
    }
  }

  private static func begin(_ started: BGContinuedProcessingTask) {
    pending = false
    guard busy, task == nil else { return started.setTaskCompleted(success: true) }
    task = started
    started.updateTitle(title, subtitle: summary)
    // The user's stop and the system's expiry both land here, and iOS does
    // not say which. Off screen the app is suspended next, which would cut
    // the work off anyway, so each held job with a stop is asked to stop, as
    // its Android notification's button would; in front, the work goes on,
    // killable again, as on Android when its service times out. A backup has
    // no stop: it is left to finish or be cut off.
    started.expirationHandler = {
      DispatchQueue.main.async {
        if task === started {
          drop()
          if UIApplication.shared.applicationState != .active {
            var jobs: [String] = []
            if turns > 0 { jobs.append("turns") }
            if download != nil { jobs.append("download") }
            if signInPlan != nil { jobs.append("signIn") }
            if syncNames != nil { jobs.append("sync") }
            jobs.forEach { channel?.invokeMethod("stopRequested", arguments: $0) }
          }
        }
        started.setTaskCompleted(success: false)
      }
    }
    started.progress.totalUnitCount = 60
    heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick(started.progress) }
  }

  /// The system expires a task whose progress stalls. A download alone has a
  /// real fraction, kilobytes as Android's bar counts them, and stalls only
  /// when it does. Nothing else that holds the task knows its length — a
  /// turn, a setup, a backup, a connection — so held is alive, and the
  /// progress moves a tick a second against a total kept a minute ahead.
  private static func tick(_ progress: Progress) {
    if let download, download.total > 0, turns == 0, !settingUp, !backingUp {
      progress.totalUnitCount = download.total / 1024
      progress.completedUnitCount = download.received / 1024
    } else {
      progress.completedUnitCount += 1
      progress.totalUnitCount = progress.completedUnitCount + 60
    }
  }

  private static func drop() {
    heartbeat?.invalidate()
    heartbeat = nil
    task = nil
  }

  private static func finish() {
    guard let task else { return }
    drop()
    task.progress.completedUnitCount = task.progress.totalUnitCount
    task.setTaskCompleted(success: true)
  }
}
