import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
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