import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // A wake whose app already runs leaves at once: no second engine over
    // one store, and the running copy's own timer is what fires its due.
    // Direct-exec launches are not deduplicated by launch services the way
    // `open` is, so this is the guard the wake command line relies on.
    if AppDelegate.wake {
      let others = NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == Bundle.main.bundleIdentifier
            && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
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

    // A wake session is not an opening anyone is watching: the trigger's
    // launchd job started the process, the window stays behind, and the
    // drained session quits from doneFiring. The first activation hereafter
    // is the user's, which shows the window and stops the session being a
    // wake — an observer rather than a delegate override, so no delegate the
    // framework forwards through is displaced.
    if AppDelegate.wake {
      self.orderOut(nil)
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil,
        queue: .main
      ) { _ in
        AppDelegate.userShowedUp = true
        for window in NSApplication.shared.windows
        where window is MainFlutterWindow && !window.isVisible {
          window.makeKeyAndOrderFront(nil)
        }
      }
    }

    super.awakeFromNib()
  }
}