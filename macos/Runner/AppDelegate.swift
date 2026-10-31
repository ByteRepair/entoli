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

  /// The process's one fork in the road, before AppKit loads anything. A
  /// model host launch — the app started this copy of its own executable,
  /// with `entoli-models`, to run the on-device models so their GPU work is
  /// not in the process that draws the window — never loads the main nib, so
  /// it has no window, no menu and no delegate of the app's: `ModelHost` is
  /// all it runs. Everything else is the app. See "The model host" in
  /// macos/AGENTS.md.
  static func main() {
    if ProcessInfo.processInfo.arguments.contains("entoli-models") {
      let app = NSApplication.shared
      app.setActivationPolicy(.prohibited)
      ModelHost.start()
      app.run()
    } else {
      _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}