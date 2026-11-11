import SwiftUI

#if os(iOS)
  import Flutter
  import UIKit
#else
  import AppKit
  import FlutterMacOS
#endif

/// The window's root from launch, whichever frontend Dart picks: the Flutter
/// view controller the runner made is always its child, drawn alone until
/// Dart says `shell(on: true)`, so Flutter's controller is never the window's
/// root and is never moved out of one. The runner's window, its channels and
/// its wake paths are untouched. One per process: there is one window.
final class ShellHost {
  static var shared: ShellHost?

  private let model: ShellModel

  #if os(macOS)
    private weak var view: NSView?
    private var host: NSHostingController<ShellRoot>?
    private var pointerMonitor: Any?

    init(messenger: FlutterBinaryMessenger, view: NSView?) {
      model = ShellModel(messenger: messenger)
      self.view = view
      listen(messenger)
    }
  #else
    private var host: UIHostingController<ShellRoot>?

    init(messenger: FlutterBinaryMessenger) {
      model = ShellModel(messenger: messenger)
      listen(messenger)
    }
  #endif

  private func listen(_ messenger: FlutterBinaryMessenger) {
    NativeShellSetup.setUp(binaryMessenger: messenger, api: model)
    model.onShell = { [weak self] in self?.chrome() }
  }

  #if os(macOS)
    /// From the plugin's registration, inside the runner's `awakeFromNib`:
    /// the Flutter controller is the window's content and nothing is shown.
    func install() {
      guard host == nil, let window = view?.window,
        let flutter = window.contentViewController
      else { return }
      let frame = window.frame
      let host = NSHostingController(rootView: ShellRoot(model: model, flutter: flutter))
      // The window keeps the size it has; nothing SwiftUI lays out asks it
      // for another.
      host.sizingOptions = []
      host.sceneBridgingOptions = []
      window.contentViewController = host
      window.setFrame(frame, display: true)
      self.host = host
    }

    /// What the chrome needs of the window, set when Dart turns it on.
    private func chrome() {
      guard let host, let window = host.view.window else { return }
      let flutter = host.rootView.flutter
      // The split view's toolbar and title are the window's own.
      host.sceneBridgingOptions = [.toolbars, .title]
      window.styleMask.insert(.fullSizeContentView)
      window.toolbarStyle = .unified
      window.acceptsMouseMovedEvents = true
      pointerMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
      ) { [weak self, weak window] event in
        guard let self, let window, event.window === window
        else { return event }
        let flutterView = flutter.view
        // Convert into Flutter's own view coordinates. The sidebar lies to
        // its left, so its x values must be negative relative to the avatar;
        // AppKit's bottom-left origin also needs flipping to Flutter's top-left.
        let point = flutterView.convert(event.locationInWindow, from: nil)
        self.model.say.window.pointer(
          x: point.x - flutterView.bounds.minX,
          y: flutterView.bounds.maxY - point.y
        ) { _ in }
        return event
      }
      // The app's, not the window's: popovers, menus and sheets are windows
      // of their own, and the system's glass follows the app. Nil follows
      // the system.
      model.onWindow = { state in
        NSApp.appearance = state.colorScheme.map {
          NSAppearance(named: $0 == .dark ? .darkAqua : .aqua)
        } ?? nil
      }
      model.onWindow?(model.window)
    }
  #else
    /// From the scene's connection: the storyboard has made the window, its
    /// root the Flutter view controller, and not yet shown it.
    func install(in scene: UIScene) {
      guard host == nil,
        let window = (scene as? UIWindowScene)?.windows
          .first(where: { $0.rootViewController is FlutterViewController }),
        let flutter = window.rootViewController
      else { return }
      let host = UIHostingController(rootView: ShellRoot(model: model, flutter: flutter))
      window.rootViewController = host
      self.host = host
    }

    private func chrome() {
      guard let window = host?.view.window else { return }
      // The window's, which is the app's here: a popover and a sheet are
      // presented from it and take its style.
      model.onWindow = { [weak window] state in
        window?.overrideUserInterfaceStyle =
          switch state.colorScheme {
          case .dark: .dark
          case .light: .light
          default: .unspecified
          }
      }
      model.onWindow?(model.window)
    }
  #endif
}

/// The window's content: the Flutter frontend alone, filling the window as
/// it did when it was the root, or the shell's chrome around it.
struct ShellRoot: View {
  @ObservedObject var model: ShellModel
  let flutter: PlatformViewController

  var body: some View {
    if model.shell {
      ShellView(model: model, flutter: flutter)
    } else {
      FlutterPane(controller: flutter).ignoresSafeArea()
    }
  }
}
