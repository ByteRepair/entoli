#if os(iOS)
  import SwiftUI
  import UIKit

  extension View {
    /// [action] on a swipe in from the leading edge, over whatever is drawn
    /// here — the Flutter view's touches included, which a SwiftUI gesture
    /// does not see. Nothing while [action] is nil, so the edge is then
    /// whoever's is under it. iOS 18's bridge for a UIKit recognizer: 17 has
    /// no swipe, only the button.
    @ViewBuilder func edgeSwipe(_ action: (() -> Void)?) -> some View {
      if #available(iOS 18.0, *) {
        gesture(EdgeSwipe(action: action))
      } else {
        self
      }
    }
  }

  /// A pan begun at the leading edge and moving across, rather than the
  /// system's edge pan, which wants a touch on the screen's very edge and
  /// misses a thumb a few points in.
  @available(iOS 18.0, *)
  private struct EdgeSwipe: UIGestureRecognizerRepresentable {
    static let edge: CGFloat = 24

    let action: (() -> Void)?

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
      let pan = UIPanGestureRecognizer()
      // Alongside what is under it, so a drag that turns out not to be one
      // still reaches the page.
      pan.cancelsTouchesInView = false
      pan.delegate = context.coordinator
      return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
      pan.isEnabled = action != nil
    }

    /// Far enough or fast enough, as the system's own back swipe decides.
    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
      guard pan.state == .ended, let view = pan.view else { return }
      if pan.translation(in: view).x > view.bounds.width / 3 || pan.velocity(in: view).x > 500 {
        action?()
      }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> FromEdge { FromEdge() }

    final class FromEdge: NSObject, UIGestureRecognizerDelegate {
      func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else {
          return false
        }
        let start = pan.location(in: view).x - pan.translation(in: view).x
        let velocity = pan.velocity(in: view)
        return start <= EdgeSwipe.edge && velocity.x > abs(velocity.y)
      }

      func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
      ) -> Bool { true }
    }
  }
#endif
