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
  }
}

/// The window's content: the frontend the core picked. Nothing but the
/// window's colour until Dart says which, so the Flutter view is put in one
/// place once — Flutter's alone, filling the window, or the shell's around
/// it.
public struct FrontendView: View {
  @ObservedObject private var model: ShellModel
  private let flutter: PlatformViewController

  public init(flutter: PlatformViewController) {
    model = ShellModel.shared!
    self.flutter = flutter
  }

  public var body: some View {
    switch model.frontend {
    case true?: ShellView(model: model, flutter: flutter)
    case false?: FlutterPane(controller: flutter).ignoresSafeArea()
    case nil: Rectangle().fill(.background).ignoresSafeArea()
    }
  }
}
