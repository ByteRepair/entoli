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

  /// A model host launch: the app started this copy of its own executable to
  /// run the on-device models, so their GPU work is not in the process that
  /// draws the window. No window and no Dock icon; `ModelHost` is all it
  /// runs. See "The model host" in macos/AGENTS.md.
  static let modelHost = ProcessInfo.processInfo.arguments.contains("entoli-models")

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // A model host has closed its window by design and lives until the app
    // that started it goes.
    return !AppDelegate.modelHost
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}