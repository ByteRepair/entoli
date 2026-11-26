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

  /// One held job: what the subtitle says of it, and the `BackgroundJob` its
  /// stop asks Dart to end, where it has one.
  private struct Job {
    let subtitle: String
    let stop: String?
  }

  /// The held jobs by the channel method that reported them, in the order
  /// the subtitle names them.
  private static var held: [String: Job] = [:]
  private static let order = [
    "running", "settingUp", "downloading", "backingUp", "signingIn", "syncing",
  ]

  private static var task: BGContinuedProcessingTask?
  /// Submitted, its launch handler not yet run.
  private static var pending = false
  /// The jobs held when the user stopped the activity in front. They go on,
  /// unheld, and only a job not among them holds again: otherwise a
  /// download's next percent would bring the activity straight back.
  private static var declined: Set<String> = []
  private static var heartbeat: Timer?
  private static var channel: FlutterMethodChannel?

  private static var busy: Bool { !held.isEmpty }

  /// Each held job in the words Android's notification uses for it, worded
  /// here rather than in Dart since the port carries counts and labels.
  private static var summary: String {
    order.compactMap { held[$0]?.subtitle }.joined(separator: " · ")
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
    let job: Job?
    switch call.method {
    case "running":
      let turns = (call.arguments as? NSNumber)?.intValue ?? 0
      job = turns == 0
        ? nil : Job(subtitle: turns == 1 ? "Running a turn" : "Running \(turns) turns", stop: "turns")
    case "settingUp":
      job = (call.arguments as? Bool) == true ? Job(subtitle: "Setting up tools", stop: nil) : nil
    case "downloading":
      job = (call.arguments as? [String: Any]).map { notice in
        let label = notice["label"] as? String ?? "a model"
        let received = (notice["received"] as? NSNumber)?.int64Value ?? 0
        let total = (notice["total"] as? NSNumber)?.int64Value ?? 0
        let percent = total > 0 ? " (\(received * 100 / total)%)" : ""
        return Job(subtitle: "Downloading \(label)\(percent)", stop: "download")
      }
    // No stop: cut off part-way, a backup is a broken file.
    case "backingUp":
      job = (call.arguments as? String).map {
        Job(subtitle: $0 == "restoring" ? "Restoring a backup" : "Writing a backup", stop: nil)
      }
    case "signingIn":
      job = (call.arguments as? String).map {
        Job(subtitle: "Waiting for you to sign in to \($0)", stop: "signIn")
      }
    case "syncing":
      job = (call.arguments as? [String: Any]).map { notice in
        let names = notice["names"] as? [String] ?? []
        return Job(
          subtitle: names.count == 1 ? "Connected to \(names[0])" : "\(names.count) devices connected",
          stop: "sync")
      }
    // Not held: the prefill is MLX's, and iOS gives the GPU only to the app
    // in front, so off screen it would fail rather than finish.
    default: return result(FlutterMethodNotImplemented)
    }
    held[call.method] = job
    update()
    result(nil)
  }

  private static func update() {
    declined.formIntersection(held.keys)
    guard busy else { return finish() }
    if task == nil && !pending && !Set(held.keys).isSubset(of: declined) { submit() }
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
            for stop in held.values.compactMap(\.stop) {
              channel?.invokeMethod("stopRequested", arguments: stop)
            }
          } else {
            declined = Set(held.keys)
          }
        }
        started.setTaskCompleted(success: false)
      }
    }
    // The system expires a task whose progress stalls, and nothing that holds
    // it knows its length: a turn, a setup, a backup, a connection. Even a
    // download's percent is reported only as it moves, which on a slow link
    // is minutes, so its share is the subtitle's. Held is alive, so the
    // progress moves while it is held, a minute ahead.
    started.progress.totalUnitCount = 60
    heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
      started.progress.completedUnitCount += 1
      started.progress.totalUnitCount = started.progress.completedUnitCount + 60
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
