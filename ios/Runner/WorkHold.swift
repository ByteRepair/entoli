import ActivityKit
import BackgroundTasks
import Flutter
import UIKit

/// Answers `agent_chat/background`, the channel Android's foreground services
/// answer: while a turn or a setup runs, a continued-processing task keeps the
/// app running off screen and a Live Activity shows it, with a Stop. See
/// "Running off screen" in ios/AGENTS.md.
enum WorkHold {
  private static let taskPrefix = "io.byterepair.entoli.work"

  private static var channel: FlutterMethodChannel?
  private static var state = WorkAttributes.ContentState(turns: 0, settingUp: false)
  private static var steps: Int64 = 0
  private static var stepsAtStart: Int64 = 0
  private static var task: BGContinuedProcessingTask?
  /// Submitted, its launch handler not yet run.
  private static var pending = false
  private static var activity: Activity<WorkAttributes>?

  private static var busy: Bool { state.turns > 0 || state.settingUp }

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "agent_chat/background", binaryMessenger: messenger)
    channel.setMethodCallHandler(handle)
    self.channel = channel
    NotificationCenter.default.addObserver(
      forName: StopWorkIntent.requested, object: nil, queue: .main
    ) { _ in channel.invokeMethod("stopRequested", arguments: "turns") }
    // Both are refused from the background: work that began there, or a task
    // the system expired, is held again once the app is in front.
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in if busy { update() } }
    // An activity left by a process that was killed mid-turn.
    for stale in Activity<WorkAttributes>.activities {
      Task { await stale.end(nil, dismissalPolicy: .immediate) }
    }
  }

  private static func handle(_ call: FlutterMethodCall, _ result: FlutterResult) {
    switch call.method {
    case "running": state.turns = (call.arguments as? NSNumber)?.intValue ?? 0
    case "settingUp": state.settingUp = (call.arguments as? Bool) ?? false
    case "stepped":
      steps = (call.arguments as? NSNumber)?.int64Value ?? steps
      report()
      return result(nil)
    default: return result(FlutterMethodNotImplemented)
    }
    update()
    result(nil)
  }

  private static func update() {
    guard busy else {
      finish()
      hide()
      return
    }
    if task == nil && !pending { submit() }
    task?.updateTitle("Entoli", subtitle: state.summary)
    report()
    show()
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
      identifier: identifier, title: "Entoli", subtitle: state.summary)
    // Queued, the task would say the work is waiting while it already runs.
    request.strategy = .fail
    do {
      try BGTaskScheduler.shared.submit(request)
      pending = true
      stepsAtStart = steps
    } catch {
      NSLog("[background] the continued task was refused: %@", "\(error)")
    }
  }

  private static func begin(_ started: BGContinuedProcessingTask) {
    pending = false
    guard busy, task == nil else { return started.setTaskCompleted(success: true) }
    task = started
    started.updateTitle("Entoli", subtitle: state.summary)
    // The system's, not the user's: the work goes on, killable again, as on
    // Android when its service times out. The user's stop is the activity's.
    started.expirationHandler = {
      DispatchQueue.main.async {
        if task === started { task = nil }
        started.setTaskCompleted(success: false)
      }
    }
    report()
  }

  /// Steps taken against at least one still to come per turn: the task must
  /// move or the system expires it as stalled, and no turn knows its length.
  private static func report() {
    guard let task else { return }
    let done = steps - stepsAtStart
    task.progress.totalUnitCount = done + Int64(max(state.turns, 1))
    task.progress.completedUnitCount = done
  }

  private static func finish() {
    guard let task else { return }
    self.task = nil
    task.progress.completedUnitCount = task.progress.totalUnitCount
    task.setTaskCompleted(success: true)
  }

  private static func show() {
    let content = ActivityContent(state: state, staleDate: nil)
    if let activity {
      Task { await activity.update(content) }
      return
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    do {
      activity = try Activity.request(attributes: WorkAttributes(started: .now), content: content)
    } catch {
      NSLog("[background] the Live Activity was refused: %@", "\(error)")
    }
  }

  private static func hide() {
    guard let activity else { return }
    self.activity = nil
    Task { await activity.end(nil, dismissalPolicy: .immediate) }
  }
}
