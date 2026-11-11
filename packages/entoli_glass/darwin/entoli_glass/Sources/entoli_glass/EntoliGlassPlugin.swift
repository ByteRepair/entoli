#if os(iOS)
  import Flutter
  import UIKit
#else
  import FlutterMacOS
  import AppKit
#endif

/// The native shell's plugin: one file of source for both Runners
/// (`sharedDarwinSource`), the platform's own halves behind `#if os(...)`.
/// The host takes the window at launch, before it is shown: macOS as the
/// runner registers its plugins, iOS as the scene connects. Dart then says
/// which frontend draws in it.
#if os(macOS)
  public final class EntoliGlassPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
      let host = ShellHost(messenger: registrar.messenger, view: registrar.view)
      ShellHost.shared = host
      host.install()
    }
  }
#else
  public final class EntoliGlassPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
      let host = ShellHost(messenger: registrar.messenger())
      ShellHost.shared = host
      // The engine registers before the scene connects, and Flutter forwards
      // a connection only to an engine whose view is already in it, so
      // `addSceneDelegate` never hears this one. The notification comes with
      // the storyboard's window made and hidden, Flutter's view not loaded.
      var observer: NSObjectProtocol?
      observer = NotificationCenter.default.addObserver(
        forName: UIScene.willConnectNotification, object: nil, queue: nil
      ) { note in
        guard let scene = note.object as? UIScene else { return }
        host.install(in: scene)
        if let observer { NotificationCenter.default.removeObserver(observer) }
      }
    }
  }
#endif
