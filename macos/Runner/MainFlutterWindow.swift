import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // A wake whose app already runs leaves at once: no second engine over
    // one store, and the running copy's own timer is what fires its due.
    // Direct-exec launches are not deduplicated by launch services the way
    // `open` is, so this is the guard the wake command line relies on. The
    // same executable, not just the same bundle id: another copy (a debug
    // build, a second install) serves its own store and fires none of ours.
    if AppDelegate.wake {
      let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
      let others = NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == Bundle.main.bundleIdentifier
            && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && $0.executableURL?.resolvingSymlinksInPath() == executable
      }
      if others {
        exit(0)
      }
    }

    // A model host runs a headless engine of its own instead of this window's:
    // the storyboard's window still loads, so it is closed once AppKit has
    // finished putting it up, and the policy keeps a Dock icon from showing.
    if AppDelegate.modelHost {
      NSApp.setActivationPolicy(.prohibited)
      ModelHost.start()
      super.awakeFromNib()
      DispatchQueue.main.async { self.close() }
      return
    }

    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    ModelHostLauncher.register(with: flutterViewController.engine.binaryMessenger)

    RemindersPlugin.register(with: flutterViewController.engine.binaryMessenger)
    ClipboardChannel.register(with: flutterViewController.engine.binaryMessenger)
    VoiceChannel.register(with: flutterViewController.engine.binaryMessenger)
    AppleFmChannel.register(with: flutterViewController.engine.binaryMessenger)

    // A wake session is not an opening anyone is watching: the trigger's
    // launchd job started the process, and hiding is the application's own —
    // `orderOut` alone loses to AppKit's visible-at-launch ordering, which
    // re-fronts the window after this method returns, so the whole app hides
    // instead (the -j launch flag this replaces never ran an engine). The
    // first activation hereafter is the user's, which unhides the app,
    // shows the window, and stops the session being a wake — an observer
    // rather than a delegate override, so no delegate the framework
    // forwards through is displaced.
    if AppDelegate.wake {
      self.orderOut(nil)
      NSApp.hide(nil)
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil,
        queue: .main
      ) { _ in
        AppDelegate.userShowedUp = true
        NSApp.unhide(nil)
        for window in NSApplication.shared.windows
        where window is MainFlutterWindow && !window.isVisible {
          window.makeKeyAndOrderFront(nil)
        }
      }
    }

    super.awakeFromNib()
  }
}

/// The model host's engine: `modelHostMain` with no view, `AppleFmChannel`
/// the one native piece registered on it, and a watch on the app that
/// started it. In this file rather than its own so the Xcode project needs no
/// new entry. See "The model host" in macos/AGENTS.md.
enum ModelHost {
  private static var engine: FlutterEngine?
  private static var parent: DispatchSourceProcess?

  static func start() {
    // The Dart code is the app's: this bundle is `Contents/Helpers/Entoli
    // Models.app` inside it, and carries no copy of its own.
    let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    let project = FlutterDartProject(
      precompiledDartBundle: Bundle(url: app.appendingPathComponent("Frameworks/App.framework")))
    // What follows the flag is the socket to connect to, then the app's pid.
    let arguments = Array(
      ProcessInfo.processInfo.arguments.drop { $0 != "entoli-models" }.dropFirst())
    project.dartEntrypointArguments = arguments
    let engine = FlutterEngine(name: "models", project: project, allowHeadlessExecution: true)
    AppleFmChannel.register(with: engine.binaryMessenger)
    let channel = FlutterMethodChannel(
      name: "agent_chat/model_host", binaryMessenger: engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "quit" else { return result(FlutterMethodNotImplemented) }
      result(nil)
      quit()
    }
    engine.run(withEntrypoint: "modelHostMain")
    self.engine = engine
    // Opened through LaunchServices, this host's parent is launchd: the app
    // is the pid it was handed.
    watch(arguments.count > 1 ? pid_t(arguments[1]) ?? 0 : 0)
  }

  /// Stops the generations, then leaves through `_exit`. `exit` runs the C++
  /// static destructors, MLX's Metal device among them, while a generation
  /// may still be encoding on another thread — the crash every quit during an
  /// MLX turn used to end in. Bounded, so a generation that will not stop
  /// cannot keep a host alive past its app.
  static func quit() {
    Task { @MainActor in
      await AppleFmChannel.stopAll()
      _exit(0)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { _exit(0) }
  }

  /// The app going, however it goes — a crash closes no socket in time to be
  /// read — is this host going. No pid to watch is no app to serve.
  private static func watch(_ pid: pid_t) {
    guard pid > 1 else { return quit() }
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    source.setEventHandler { quit() }
    source.resume()
    parent = source
    // Gone before the source was armed, which it would never report.
    if kill(pid, 0) != 0 { quit() }
  }
}

/// Opens the model host — `Contents/Helpers/Entoli Models.app` — as an
/// application of its own, through LaunchServices rather than as a child: a
/// child is this app's to macOS, its GPU work scheduled as the app's own
/// beside the window's frames. The key the host proves itself with goes in
/// its environment, which no other process can read, where an `open --env`
/// would have put it on a command line any process can. In this file rather
/// than its own so the Xcode project needs no new entry.
enum ModelHostLauncher {
  static func register(with messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "agent_chat/model_host_launcher", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        guard call.method == "open", let args = call.arguments as? [String: Any] else {
          return result(FlutterMethodNotImplemented)
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent(
          "Contents/Helpers/Entoli Models.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = args["arguments"] as? [String] ?? []
        configuration.environment = args["environment"] as? [String: String] ?? [:]
        NSWorkspace.shared.openApplication(at: helper, configuration: configuration) {
          _, error in
          DispatchQueue.main.async {
            if let error {
              result(FlutterError(code: "open", message: error.localizedDescription, details: nil))
            } else {
              result(nil)
            }
          }
        }
      }
  }
}

/// The copy with formatting, which Flutter's own clipboard call cannot make:
/// it writes plain text only. And the files a paste brings, which it cannot
/// read. See rich_clipboard.dart and clipboard_files.dart. In this file rather
/// than its own so the Xcode project needs no new entry.
enum ClipboardChannel {
  private static var channel: FlutterMethodChannel?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "agent_chat/clipboard", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "setHtml":
        guard let args = call.arguments as? [String: Any],
              let plain = args["plain"] as? String, let html = args["html"] as? String
        else { return result(FlutterError(code: "bad-args", message: "plain and html", details: nil)) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(html, forType: .html)
        pasteboard.setString(plain, forType: .string)
        result(nil)
      case "readFiles":
        result(readFiles())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// A Finder copy carries the names as text too, so files win over text, and
  /// text over an image: a spreadsheet's cells come with a picture of
  /// themselves.
  private static func readFiles() -> [[String: Any]] {
    let pasteboard = NSPasteboard.general
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      !urls.isEmpty
    {
      return urls.map { ["path": $0.path] }
    }
    if pasteboard.string(forType: .string) != nil { return [] }
    let png = pasteboard.data(forType: .png)
      ?? pasteboard.data(forType: .tiff).flatMap {
        NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
      }
    guard let png else { return [] }
    return [["bytes": FlutterStandardTypedData(bytes: png)]]
  }
}
