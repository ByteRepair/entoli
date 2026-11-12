#if os(iOS)
  import SwiftUI
  import UIKit

  /// An iPhone's sidebar: the list beneath the chat, which the chat slides off
  /// and back over under the finger, as a stack's back swipe moves a page.
  /// The split view shows one column at a time with nothing between, so a
  /// swipe there could only fire once it ended; this is the one-column
  /// layout instead. [column] is `compactColumn`, written when a swipe
  /// settles, and a button's write of it slides the same way.
  struct Drawer<List: View, Detail: View>: View {
    @Binding var column: NavigationSplitViewColumn
    /// Whether a swipe in from the leading edge opens it: not under a Flutter
    /// page, which keeps the edge for its own back swipe.
    let opens: Bool
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail

    @State private var width: CGFloat = 0
    @State private var shown = false
    /// The finger's travel across, while a swipe is under way.
    @State private var pull: CGFloat?

    private var offset: CGFloat {
      min(max((shown ? width : 0) + (pull ?? 0), 0), width)
    }

    var body: some View {
      let progress = width > 0 ? offset / width : (shown ? 1 : 0)
      ZStack {
        list
          .offset(x: -width * drawerParallax * (1 - progress))
          .overlay {
            Color.black.opacity(0.12 * (1 - progress)).ignoresSafeArea().allowsHitTesting(false)
          }
          .accessibilityHidden(!shown)
          .allowsHitTesting(shown)
        detail
          .background(alignment: .leading) {
            // A strip, not the detail's own shadow: that would render the
            // whole Flutter view offscreen on every frame of the slide.
            LinearGradient(
              colors: [.clear, .black.opacity(0.18)], startPoint: .leading, endPoint: .trailing
            )
            .frame(width: 14)
            .offset(x: -14)
            .opacity(progress > 0 ? 1 : 0)
            .ignoresSafeArea()
          }
          .offset(x: offset)
          .accessibilityHidden(shown)
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
      .drawerPan(shown: shown, opens: opens, moved: { pull = $0 }, ended: settle)
      .onAppear { shown = column == .sidebar }
      .onChange(of: column) { _, column in
        let open = column == .sidebar
        guard open != shown else { return }
        withAnimation(.smooth(duration: 0.35)) { shown = open }
      }
    }

    /// A flick goes the way it was flicked, as a stack's back swipe does; a
    /// slow drag goes where it was let go. The spring starts at its speed.
    private func settle(travel: CGFloat, velocity: CGFloat) {
      let from = min(max((shown ? width : 0) + travel, 0), width)
      let open = abs(velocity) > 300 ? velocity > 0 : from > width / 2
      let remaining = (open ? width : 0) - from
      let relative = abs(remaining) > 1 ? velocity / remaining : 0
      withAnimation(.interpolatingSpring(duration: 0.4, bounce: 0, initialVelocity: relative)) {
        shown = open
        pull = nil
      }
      let wanted: NavigationSplitViewColumn = open ? .sidebar : .detail
      if column != wanted { column = wanted }
    }
  }

  /// How far the list lags the chat, as a stack's page beneath does.
  private let drawerParallax: CGFloat = 0.3

  extension View {
    /// The drawer's swipe, over whatever is drawn here — the Flutter view's
    /// touches included, which a SwiftUI gesture does not see.
    fileprivate func drawerPan(
      shown: Bool, opens: Bool, moved: @escaping (CGFloat) -> Void,
      ended: @escaping (CGFloat, CGFloat) -> Void
    ) -> some View {
      gesture(DrawerPan(shown: shown, opens: opens, moved: moved, ended: ended))
    }
  }

  /// Its own class, so a control's stretch can tell it from the rest.
  final class DrawerRecognizer: UIPanGestureRecognizer {}

  /// Closed, a pan begun at the leading edge and moving across — a few points
  /// in, rather than the system's edge pan, which misses a thumb that is not
  /// on the very edge. Open, a pan toward the edge anywhere.
  private struct DrawerPan: UIGestureRecognizerRepresentable {
    static let edge: CGFloat = 24

    let shown: Bool
    let opens: Bool
    let moved: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> DrawerRecognizer {
      let pan = DrawerRecognizer()
      pan.delegate = context.coordinator
      return pan
    }

    func updateUIGestureRecognizer(_ pan: DrawerRecognizer, context: Context) {
      context.coordinator.shown = shown
      context.coordinator.opens = opens
    }

    func handleUIGestureRecognizerAction(_ pan: DrawerRecognizer, context: Context) {
      guard let view = pan.view else { return }
      switch pan.state {
      case .began, .changed: moved(pan.translation(in: view).x)
      case .ended: ended(pan.translation(in: view).x, pan.velocity(in: view).x)
      case .cancelled, .failed: ended(0, 0)
      default: break
      }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
      var shown = false
      var opens = false

      func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else {
          return false
        }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        if shown { return velocity.x < 0 }
        let start = pan.location(in: view).x - pan.translation(in: view).x
        return opens && start <= DrawerPan.edge && velocity.x > 0
      }

      func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
      ) -> Bool { !(other is StretchPan) }

      /// A control's stretch waits on the drawer, so a swipe in from the edge
      /// that starts on the composer's `+` opens the list rather than pulling
      /// the button.
      func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
      ) -> Bool { other is StretchPan }
    }
  }
#endif
