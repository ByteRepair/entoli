import SwiftUI

#if os(iOS)
  import Flutter
  import UIKit
#else
  import AppKit
  import FlutterMacOS
#endif

/// The shell's host: on `start`, the window's content becomes SwiftUI's, with
/// the Flutter view controller the runner made embedded in it. The runner's
/// window, its channels and its wake paths are untouched; only what fills the
/// window changes. One per process: there is one window, and the shell is its.
final class ShellHost {
  static var shared: ShellHost?

  private let model: ShellModel

  #if os(macOS)
    private weak var view: NSView?
    private var host: NSHostingController<ShellView>?
    private var pointerMonitor: Any?

    init(messenger: FlutterBinaryMessenger, view: NSView?) {
      model = ShellModel(messenger: messenger)
      self.view = view
      listen(messenger)
    }
  #else
    private var host: UIHostingController<ShellView>?

    init(messenger: FlutterBinaryMessenger) {
      model = ShellModel(messenger: messenger)
      listen(messenger)
    }
  #endif

  /// What Dart says, to the model; and `start`, to this.
  private func listen(_ messenger: FlutterBinaryMessenger) {
    model.onStart = { [weak self] in self?.start() }
    NativeShellSetup.setUp(binaryMessenger: messenger, api: model)
  }

  #if os(macOS)
    private func start() {
      guard host == nil, let window = view?.window,
        let flutter = window.contentViewController
      else { return }
      let frame = window.frame
      let host = NSHostingController(rootView: ShellView(model: model, flutter: flutter))
      // The window keeps the size it has; nothing SwiftUI lays out asks it
      // for another.
      host.sizingOptions = []
      // The split view's toolbar and title are the window's own.
      host.sceneBridgingOptions = [.toolbars, .title]
      window.styleMask.insert(.fullSizeContentView)
      window.toolbarStyle = .unified
      window.contentViewController = host
      window.setFrame(frame, display: true)
      self.host = host
      window.acceptsMouseMovedEvents = true
      pointerMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
      ) { [weak self, weak window] event in
        guard let self, let window, event.window === window,
          let content = window.contentView
        else { return event }
        let point = content.convert(event.locationInWindow, from: nil)
        self.model.say.window.pointer(
          x: point.x - content.bounds.minX, y: content.bounds.maxY - point.y
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
    /// The scene's window, whose root the runner's storyboard made the
    /// Flutter view controller.
    private var window: UIWindow? {
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first { $0.rootViewController is FlutterViewController }
    }

    private func start() {
      guard host == nil, let window, let flutter = window.rootViewController
      else { return }
      let host = UIHostingController(rootView: ShellView(model: model, flutter: flutter))
      window.rootViewController = host
      self.host = host
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
