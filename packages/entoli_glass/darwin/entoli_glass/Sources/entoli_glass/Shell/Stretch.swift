import SwiftUI

#if os(iOS)
  import UIKit
#endif

/// A glass control the finger can pull, as the system's own glass can be: it
/// follows a drag a short, resisting way, stretched along it, and springs
/// back when let go. Inside a `GlassGroup` a control pulled near its
/// neighbour runs into it, the container blending glass that comes within
/// its spacing. iOS alone: a pointer has nothing to pull.
struct Stretchy: ViewModifier {
  /// Off for a control with a press of its own to hold, as push-to-talk's.
  var on = true
  @State private var pull = CGSize.zero

  /// How far the control can be pulled, however far the finger goes.
  private static let reach: CGFloat = 36

  private static func band(_ travel: CGFloat) -> CGFloat {
    let reach = Self.reach
    return (travel < 0 ? -1 : 1) * reach * (1 - exp(-abs(travel) / reach))
  }

  func body(content: Content) -> some View {
    let x = Self.band(pull.width)
    let y = Self.band(pull.height)
    let along = (x: abs(x) / Self.reach, y: abs(y) / Self.reach)
    content
      .scaleEffect(
        x: 1 + 0.16 * along.x - 0.07 * along.y, y: 1 + 0.16 * along.y - 0.07 * along.x
      )
      .offset(x: x, y: y)
      .stretchPan(on: on) {
        pull = $0
      } ended: {
        withAnimation(.spring(duration: 0.5, bounce: 0.5)) { pull = .zero }
      }
  }
}

extension View {
  func stretchy(_ on: Bool = true) -> some View {
    modifier(Stretchy(on: on))
  }

  @ViewBuilder fileprivate func stretchPan(
    on: Bool, moved: @escaping (CGSize) -> Void, ended: @escaping () -> Void
  ) -> some View {
    #if os(iOS)
      gesture(StretchGesture(on: on, moved: moved, ended: ended))
    #else
      self
    #endif
  }
}

#if os(iOS)
  /// Its own class, so the drawer's pan can tell it from the rest.
  final class StretchPan: UIPanGestureRecognizer {}

  private struct StretchGesture: UIGestureRecognizerRepresentable {
    let on: Bool
    let moved: (CGSize) -> Void
    let ended: () -> Void

    func makeUIGestureRecognizer(context: Context) -> StretchPan {
      // Cancels the touches under it once it begins, so a pulled button is
      // not pressed and a pulled field takes no tap.
      let pan = StretchPan()
      pan.delegate = context.coordinator
      return pan
    }

    func updateUIGestureRecognizer(_ pan: StretchPan, context: Context) { pan.isEnabled = on }

    /// In the window's coordinates: the control moves under the finger, and
    /// its own would move with it.
    func handleUIGestureRecognizerAction(_ pan: StretchPan, context: Context) {
      switch pan.state {
      case .began, .changed:
        let travel = pan.translation(in: nil)
        moved(CGSize(width: travel.x, height: travel.y))
      case .ended, .cancelled, .failed: ended()
      default: break
      }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
      private weak var touched: UIView?

      private var down: TimeInterval = 0

      /// A drag after a press held is the field's selection or the menu's
      /// long press, not a pull. A timer rather than waiting on those long
      /// presses to fail: one of the text view's never does as the finger
      /// moves, and the field would never pull.
      private static let held: TimeInterval = 0.35

      func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
        -> Bool
      {
        down = touch.timestamp
        touched = touch.view
        return true
      }

      func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard ProcessInfo.processInfo.systemUptime - down < Self.held else { return false }
        guard scrolls, let pan = recognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: nil)
        return abs(velocity.x) > abs(velocity.y)
      }

      /// The touch is on a field whose text overflows it: an up or down drag
      /// there scrolls it, and only one across pulls.
      private var scrolls: Bool {
        var view = touched
        while let v = view {
          if let scroll = v as? UIScrollView, scroll.isScrollEnabled,
            scroll.contentSize.height > scroll.bounds.height
          {
            return true
          }
          view = v.superview
        }
        return false
      }

      func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
      ) -> Bool { !(other is StretchPan || other is DrawerRecognizer) }
    }
  }
#endif
