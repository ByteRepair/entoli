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

  private let channel: FlutterMethodChannel
  private let model: ShellModel

  #if os(macOS)
    private weak var view: NSView?
    private var host: NSHostingController<ShellView>?

    init(messenger: FlutterBinaryMessenger, view: NSView?) {
      channel = FlutterMethodChannel(name: "entoli_glass/shell", binaryMessenger: messenger)
      model = ShellModel(channel: channel)
      self.view = view
      listen()
    }
  #else
    private var host: UIHostingController<ShellView>?

    init(messenger: FlutterBinaryMessenger) {
      channel = FlutterMethodChannel(name: "entoli_glass/shell", binaryMessenger: messenger)
      model = ShellModel(channel: channel)
      listen()
    }
  #endif

  private func listen() {
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(nil) }
      switch call.method {
      case "start":
        start()
      case "snapshot":
        let args = call.arguments as? [String: Any]
        model.apply(
          concern: args?["concern"] as? String ?? "", value: args?["value"],
          json: args?["json"] as? String)
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
