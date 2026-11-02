#if os(iOS)
  import Flutter
  import UIKit
#else
  import FlutterMacOS
  import AppKit
#endif

/// The native shell's plugin: one file of source for both Runners
/// (`sharedDarwinSource`), the platform's own halves behind `#if os(...)`.
/// Registering only listens; the shell takes the window when Dart's
/// `ShellBridge` says `start`, which it says only with Liquid Glass on.
public final class EntoliGlassPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(macOS)
      ShellHost.shared = ShellHost(messenger: registrar.messenger, view: registrar.view)
    #else
      ShellHost.shared = ShellHost(messenger: registrar.messenger())
    #endif
  }
}
