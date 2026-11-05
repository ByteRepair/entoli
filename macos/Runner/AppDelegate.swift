import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// A wake launch: the trigger's launchd job started this process, which is
  /// how a trigger fires with the app closed. `MainFlutterWindow` keeps the
  /// window behind; the Reminders plugin quits a wake session nobody came to
  /// look at once its drained work is done through `doneFiring`.
  static let wake = ProcessInfo.processInfo.arguments.contains("entoli-wake")

  /// Someone has looked at the app since it last went unwatched — a wake
  /// launch starts unwatched, and so does a close that hid a turn. Set by
  /// `MainFlutterWindow`'s activation watcher, the one signal for both.
  static var watched = !wake

  /// The wake's own work has not drained yet: until `doneFiring` says so, a
  /// wake session stays even with nothing else running.
  static var wakePending = wake

  /// The one way an unwatched session ends: nobody has looked, no turn runs
  /// (`TurnHold`) and a wake's work has drained. Called whenever one of those
  /// last two stops, so neither ends the app under the other. The quit waits
  /// behind the launchd queue, so no rewrite is cut between its bootout and
  /// its bootstrap, and a short delay lets the caller's reply reach Dart
  /// before the process goes — after which it asks again, someone having
  /// perhaps looked or a turn started in the meantime.
  static func quitIfUnwatched() {
    guard canQuit else { return }
    RemindersPlugin.launchd.async {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        if canQuit { NSApp.terminate(nil) }
      }
    }
  }

  private static var canQuit: Bool { !watched && !TurnHold.isRunning && !wakePending }

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