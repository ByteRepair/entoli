import SwiftUI

#if os(iOS)
  import UIKit
  typealias PlatformViewController = UIViewController
#else
  import AppKit
  typealias PlatformViewController = NSViewController
#endif

/// The one Flutter view controller, inside SwiftUI. It is held by a container
/// rather than handed to SwiftUI itself: SwiftUI makes a representable's
/// controller again whenever the view's identity changes, and the Flutter one
/// can have one parent at a time — so each container takes it as its child
/// when it appears, from wherever it was.
#if os(macOS)
  struct FlutterPane: NSViewControllerRepresentable {
    let controller: NSViewController

    func makeNSViewController(context: Context) -> FlutterContainer {
      FlutterContainer(flutter: controller)
    }

    func updateNSViewController(_ container: FlutterContainer, context: Context) {}
  }

  final class FlutterContainer: NSViewController {
    private let flutter: NSViewController

    init(flutter: NSViewController) {
      self.flutter = flutter
      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
      view = NSView()
      adopt()
    }

    override func viewWillAppear() {
      super.viewWillAppear()
      adopt()
    }

    private func adopt() {
      guard flutter.parent !== self else { return }
      flutter.view.removeFromSuperview()
      flutter.removeFromParent()
      addChild(flutter)
      flutter.view.frame = view.bounds
      flutter.view.autoresizingMask = [.width, .height]
      view.addSubview(flutter.view)
    }
  }
#else
  struct FlutterPane: UIViewControllerRepresentable {
    let controller: UIViewController

    func makeUIViewController(context: Context) -> FlutterContainer {
      FlutterContainer(flutter: controller)
    }

    func updateUIViewController(_ container: FlutterContainer, context: Context) {}
  }

  final class FlutterContainer: UIViewController {
    private let flutter: UIViewController

    init(flutter: UIViewController) {
      self.flutter = flutter
      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func viewDidLoad() {
      super.viewDidLoad()
      adopt()
    }

    override func viewWillAppear(_ animated: Bool) {
      super.viewWillAppear(animated)
      adopt()
    }

    private func adopt() {
      guard flutter.parent !== self else { return }
      flutter.willMove(toParent: nil)
      flutter.view.removeFromSuperview()
      flutter.removeFromParent()
      addChild(flutter)
      flutter.view.frame = view.bounds
      flutter.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      view.addSubview(flutter.view)
      flutter.didMove(toParent: self)
    }
  }
#endif
