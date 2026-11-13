import FileProvider
import Flutter
import UIKit

/// The app's half of the workspaces in the Files app: it adds the provider's
/// domain, tells the provider when to look again, and opens Files at a
/// folder. See "The workspaces in the Files app" in ios/AGENTS.md.
enum FilesChannel {
  private static var channel: FlutterMethodChannel?
  private static var background: NSObjectProtocol?

  static func register(with messenger: FlutterBinaryMessenger) {
    // Added on every launch, which is a no-op for a domain already there and
    // brings back one the user removed by reinstalling.
    NSFileProviderManager.add(workspaceDomain) { error in
      if let error { NSLog("[files] adding the Files domain failed: %@", "\(error)") }
    }
    // Leaving the app is when Files is about to be opened, and nothing else
    // tells the provider a command changed a workspace.
    background = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { _ in signal() }

    let channel = FlutterMethodChannel(name: "agent_chat/files", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "reveal":
        guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
          return result(FlutterError(code: "bad-args", message: "path", details: nil))
        }
        Task { @MainActor in
          await reveal(URL(fileURLWithPath: path, isDirectory: true))
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  private static func signal() {
    NSFileProviderManager(for: workspaceDomain)?.signalEnumerator(for: .workingSet) { error in
      if let error { NSLog("[files] signalling the Files domain failed: %@", "\(error)") }
    }
  }

  /// Files at [dir], or at the nearest folder above it the tree holds.
  /// `shareddocuments://` is the scheme Files answers, with the path its
  /// user-visible URL has; where no URL comes back, Files opens where it was.
  @MainActor private static func reveal(_ dir: URL) async {
    signal()
    var target = URL(string: "shareddocuments://")!
    if let dataDir = workspaceDataDir, let manager = NSFileProviderManager(for: workspaceDomain) {
      let node = WorkspaceNode.of(dir, in: dataDir)
      for id in [node.identifier, .rootContainer] {
        guard let visible = try? await manager.getUserVisibleURL(for: id),
          var parts = URLComponents(url: visible, resolvingAgainstBaseURL: false)
        else { continue }
        parts.scheme = "shareddocuments"
        if let url = parts.url { target = url }
        break
      }
    }
    if !(await UIApplication.shared.open(target)) {
      NSLog("[files] Files would not open")
    }
  }
}
