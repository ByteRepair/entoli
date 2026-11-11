import SwiftUI

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// The native shell's plugin: one file of source for both Runners
/// (`sharedDarwinSource`). Registering only listens for what Dart says; the
/// window is the app's own `WindowGroup`, which shows `FrontendView`.
public final class EntoliGlassPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let model = ShellModel(messenger: messenger)
    ShellModel.shared = model
    NativeShellSetup.setUp(binaryMessenger: messenger, api: model)
    let settings = SettingsModel(messenger: messenger)
    SettingsModel.shared = settings
    NativeSettingsSetup.setUp(binaryMessenger: messenger, api: settings)
  }
}

/// The window's content: the frontend the core picked. Nothing but the
/// window's colour until Dart says which, so the Flutter view is put in one
/// place once — Flutter's alone, filling the window, or the shell's around
/// it.
public struct FrontendView: View {
  @ObservedObject private var model: ShellModel
  @ObservedObject private var settings: SettingsModel
  private let flutter: PlatformViewController

  public init(flutter: PlatformViewController) {
    model = ShellModel.shared!
    settings = SettingsModel.shared!
    self.flutter = flutter
  }

  public var body: some View {
    frontend
      #if os(iOS)
        // The settings are the platform's own over the app, where a Mac has
        // a Settings window of its own.
        .sheet(isPresented: $settings.presented) { SettingsRoot(model: settings) }
      #endif
  }

  @ViewBuilder private var frontend: some View {
    switch model.frontend {
    case true?: ShellView(model: model, flutter: flutter)
    case false?: FlutterPane(controller: flutter).ignoresSafeArea()
    case nil: Rectangle().fill(.background).ignoresSafeArea()
    }
  }
}
