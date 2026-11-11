import Cocoa
import FlutterMacOS
import SwiftUI
import entoli_glass
import entoli_menu

/// The process's one fork in the road, before anything of AppKit loads. A
/// model host launch — the app started this copy of its own executable, with
/// `entoli-models`, to run the on-device models so their GPU work is not in
/// the process that draws the window — has no window, no menu and no delegate
/// of the app's: `ModelHost` is all it runs. Everything else is the app. See
/// "The model host" in macos/AGENTS.md.
@main
enum Launch {
  static func main() {
    if ProcessInfo.processInfo.arguments.contains("entoli-models") {
      let app = NSApplication.shared
      app.setActivationPolicy(.prohibited)
      ModelHost.start()
      app.run()
    } else {
      EntoliApp.main()
    }
  }
}

/// The app, as SwiftUI's own template has one: its one window, whose content
/// is the frontend the core picked, and the app's menus. The Flutter engine
/// is the delegate's, started before the window is asked for.
struct EntoliApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    Window("Entoli", id: "main") {
      FrontendView(flutter: delegate.flutter)
        .background(SettingsWindowOpener())
    }
    .defaultSize(width: 1100, height: 760)
    .windowToolbarStyle(.unified)
    .commands { AppCommands() }
    // The settings, as the platform's own window, built from what Dart sends.
    Settings { SettingsWindow() }
      // One toolbar row with the title in it, as the main window has, rather
      // than a title row over a toolbar row.
      .windowToolbarStyle(.unified)
  }
}

/// A `FlutterAppDelegate` still, which is how plugins hear the app's events.
final class AppDelegate: FlutterAppDelegate {
  /// A wake launch: the trigger's launchd job started this process, which is
  /// how a trigger fires with the app closed. The app hides at launch, and
  /// the Reminders plugin quits a wake session nobody came to look at once
  /// its drained work is done through `doneFiring`.
  static let wake = ProcessInfo.processInfo.arguments.contains("entoli-wake")

  /// Someone has looked at the app since it last went unwatched — a wake
  /// launch starts unwatched, and so does a close during a turn. Set by
  /// the activation watcher, the one signal for both.
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

  let engine = FlutterEngine(name: "entoli", project: nil)

  /// The engine's view, the engine running and every plugin and channel on
  /// it, set up the first time anything asks: the window's content or the
  /// launch, whichever SwiftUI gets to first.
  @MainActor private(set) lazy var flutter: FlutterViewController = {
    let flutter = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    // Until Flutter's first frame the view is its own background, black
    // unless told otherwise: the window's colour instead.
    flutter.backgroundColor = .windowBackgroundColor
    engine.run(withEntrypoint: nil)
    RegisterGeneratedPlugins(registry: engine)
    let messenger = engine.binaryMessenger
    ModelHostLauncher.register(with: messenger)
    RemindersPlugin.register(with: messenger)
    ClipboardChannel.register(with: messenger)
    VoiceChannel.register(with: messenger)
    AppleFmChannel.register(with: messenger)
    IntentBridge.shared.register(with: messenger)
    TurnHold.register(with: messenger)
    return flutter
  }()

  /// Before AppKit says it finished launching: a plugin hears the launch
  /// through the delegate (`app_links` installs its URL handler here).
  override func applicationWillFinishLaunching(_ notification: Notification) {
    // A wake whose app already runs leaves at once: no second engine over
    // one store, and the running copy's own timer is what fires its due.
    // Direct-exec launches are not deduplicated by launch services the way
    // `open` is, so this is the guard the wake command line relies on. The
    // same executable, not just the same bundle id: another copy (a debug
    // build, a second install) serves its own store and fires none of ours.
    if Self.wake {
      let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
      let others = NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == Bundle.main.bundleIdentifier
          && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
          && $0.executableURL?.resolvingSymlinksInPath() == executable
      }
      if others { exit(0) }
    }
    // One window, so no tabs: AppKit would otherwise put Show Tab Bar and
    // Show All Tabs in the View menu.
    NSWindow.allowsAutomaticWindowTabbing = false
    _ = flutter

    // An activation is the user's — a wake's launch and a close during a turn
    // never activate — so it makes the session watched, unhides the app and
    // shows the window a wake kept back or a close took away.
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in
      Self.watched = true
      NSApp.unhide(nil)
    }
    super.applicationWillFinishLaunching(notification)
  }

  /// A wake session is not an opening anyone is watching: the trigger's
  /// launchd job started the process, so the whole app hides — a window
  /// ordered out alone loses to AppKit's visible-at-launch ordering.
  /// No `super`: `FlutterAppDelegate` has no such method, and the call
  /// throws, which AppKit swallows along with the rest of this.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    if Self.wake { NSApp.hide(nil) }
  }

  /// The last window closing quits the app, unless a turn is running: then
  /// the app stays, windowless — the Dock says it is running in the
  /// background — and goes unwatched, so the turn's end quits it unless
  /// someone comes back first. Asked here rather than of the window's close,
  /// since the native shell closes the window without `performClose`.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    guard TurnHold.isRunning else { return true }
    Self.watched = false
    return false
  }

  /// The Dock icon, or opening the app again, brings back the window a
  /// close during a turn left closed: SwiftUI reopens its `Window`.
  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool { true }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}