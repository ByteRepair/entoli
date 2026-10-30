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

    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    RemindersPlugin.register(with: flutterViewController.engine.binaryMessenger)
    ClipboardChannel.register(with: flutterViewController.engine.binaryMessenger)
    VoiceChannel.register(with: flutterViewController.engine.binaryMessenger)

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
