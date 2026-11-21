import ActivityKit
import AppIntents
import Foundation

/// The Live Activity of work running off screen. Compiled into both the
/// Runner, which starts and updates it, and the WorkActivity extension, which
/// draws it. See "Running off screen" in ios/AGENTS.md.
struct WorkAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var turns: Int
    var settingUp: Bool

    /// Android's notification text (`AgentService.kt`), worded here rather
    /// than in Dart since the port carries a count.
    var summary: String {
      switch turns {
      case 0: "Setting up tools"
      case 1: "Running a turn"
      default: "Running \(turns) turns"
      }
    }

    /// Stop ends turns; a setup alone has none to end.
    var stoppable: Bool { turns > 0 }
  }

  /// When the hold began, which the activity counts up from.
  var started: Date
}

/// The activity's Stop. A `LiveActivityIntent` is performed in the app's
/// process, so the extension only names it.
struct StopWorkIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Stop"
  static let requested = Notification.Name("io.byterepair.entoli.stopWork")

  func perform() async throws -> some IntentResult {
    await MainActor.run { NotificationCenter.default.post(name: Self.requested, object: nil) }
    return .result()
  }
}
