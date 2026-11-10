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

    /// Taken once this container has appeared, not as it loads or is about
    /// to: the controller may still be finishing a disappearance of its own.
    /// The shell's start swaps it out as the window's root, and UIKit sends
    /// that root its `viewDidDisappear` only as the new root appears — after
    /// the `viewWillAppear` it would have had here as a child. Flutter tears
    /// its surface down on a disappearance and sets it up on an appearance,
    /// so in that order it drew no frame again, and nothing said so: the
    /// lifecycle stayed resumed. Moved into a container already in the
    /// window, it gets an appearance of its own after the disappearance.
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
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
