import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// A wake launch: the trigger's launchd job started this process, which is
  /// how a trigger fires with the app closed. `MainFlutterWindow` keeps the
  /// window behind; the Reminders plugin quits a wake session nobody came to
  /// look at once its drained work is done through `doneFiring`.
  static let wake = ProcessInfo.processInfo.arguments.contains("entoli-wake")

  /// The first thing that activated the app was the user, not the wake's
  /// launch — from there on the session is an ordinary one and stays.
  /// Set by `MainFlutterWindow`'s activation watcher.
  static var userShowedUp = false

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}