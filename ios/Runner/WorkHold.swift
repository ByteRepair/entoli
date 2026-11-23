import BackgroundTasks
import Flutter
import UIKit

/// Answers `agent_chat/background`, the channel Android's foreground services
/// answer: while a turn or a setup runs, a continued-processing task keeps the
/// app running off screen, and the system shows it with its own stop. See
/// "Running off screen" in ios/AGENTS.md.
enum WorkHold {
  private static let taskPrefix = "io.byterepair.entoli.work"
  private static let title = "Entoli"

  private static var turns = 0
  private static var settingUp = false
  private static var task: BGContinuedProcessingTask?
  /// Submitted, its launch handler not yet run.
  private static var pending = false
  private static var heartbeat: Timer?
  private static var channel: FlutterMethodChannel?

  private static var busy: Bool { turns > 0 || settingUp }

  /// Android's notification text (`AgentService.kt`), worded here rather than
  /// in Dart since the port carries a count.
  private static var summary: String {
    switch turns {
    case 0: "Setting up tools"
    case 1: "Running a turn"
    default: "Running \(turns) turns"
    }
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
    // the turns off anyway, so they are stopped cleanly; in front, the work
    // goes on, killable again, as on Android when its service times out.
    started.expirationHandler = {
      DispatchQueue.main.async {
        if task === started {
          drop()
          if turns > 0 && UIApplication.shared.applicationState != .active {
            channel?.invokeMethod("stopRequested", arguments: "turns")
          }
        }
        started.setTaskCompleted(success: false)
      }
    }
    // The system expires a task whose progress stalls, and nothing that holds
    // it knows its length: a turn, its sub-agents, a long command, a setup.
    // Held is alive, so the progress moves while it is held, a minute ahead.
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
