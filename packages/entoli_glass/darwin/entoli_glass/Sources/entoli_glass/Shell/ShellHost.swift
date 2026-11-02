#if os(macOS)
  import AppKit
  import FlutterMacOS
  import SwiftUI

  /// The shell on macOS: on `start`, the window's content becomes SwiftUI's,
  /// with the Flutter view controller the runner made embedded in it. The
  /// runner's window, its channels and its wake paths are untouched; only what
  /// fills the window changes.
  final class ShellHost {
    /// The process's: there is one window, and the shell is its.
    static var shared: ShellHost?

    private let channel: FlutterMethodChannel
    private weak var view: NSView?
    private let model: ShellModel
    private var host: NSHostingController<ShellView>?

    init(messenger: FlutterBinaryMessenger, view: NSView?) {
      channel = FlutterMethodChannel(name: "entoli_glass/shell", binaryMessenger: messenger)
      model = ShellModel(channel: channel)
      self.view = view
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self else { return result(nil) }
        switch call.method {
        case "start":
          start()
        case "snapshot":
          let args = call.arguments as? [String: Any]
          model.apply(concern: args?["concern"] as? String ?? "", value: args?["value"])
        // Answered when a choice is picked or the strip is dismissed.
        case "strip":
          model.showStrip(call.arguments as? [String: Any] ?? [:]) { result($0) }
          return
        default:
          return result(FlutterMethodNotImplemented)
        }
        result(nil)
      }
    }

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
      model.onWindow = { [weak window] state in
        window?.appearance = state.appearance.map {
          NSAppearance(named: $0 == "dark" ? .darkAqua : .aqua)
        } ?? nil
      }
      model.onWindow?(model.window)
    }
  }
#endif
