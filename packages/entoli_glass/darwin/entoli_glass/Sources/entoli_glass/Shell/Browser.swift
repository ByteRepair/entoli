import ImageIO
import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// A frame of the agent's browser, decoded once, and the page's size in CSS
/// pixels that a point on it is read against.
struct BrowserFrame {
  let image: CGImage
  let page: CGSize

  init?(_ frame: BrowserFrameSnapshot) {
    guard let source = CGImageSourceCreateWithData(frame.jpeg.data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { return nil }
    self.image = image
    page = CGSize(width: frame.width, height: frame.height)
  }
}

/// The agent's browser as the user watches it: the page's title and address
/// over its live frames, with the browser's own back, forward and reload, a
/// window of its own, holding the agent off, and quitting; and the page
/// itself under the user's mouse, finger and keys. A sheet over the window,
/// so nothing under it — the composer least of all — takes input while it is
/// up.
struct BrowserSheet: View {
  @Bindable var model: ShellModel
  @Environment(\.dismiss) private var dismiss

  private var view: BrowserViewSnapshot { model.browser }
  private var say: BrowserIntents { model.say.browser }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        button("chevron.left", "Back") { say.back { _ in } }
        button("chevron.right", "Forward") { say.forward { _ in } }
        button("arrow.clockwise", "Reload") { say.reload { _ in } }
        VStack(alignment: .leading, spacing: 1) {
          Text(view.title).font(.headline).lineLimit(1)
          Text(view.url ?? "Closed").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        if view.window {
          button("macwindow", "Open in a window") { say.window { _ in } }
        }
        if view.hidden {
          button("eye", "Give back to agent", enabled: true) { say.unhide { _ in } }
        } else {
          button("eye.slash", "Hide from agent", enabled: true) { say.hide { _ in } }
        }
        button("power", "Quit the browser") { say.quit { _ in } }
        button("xmark", "Close", enabled: true) { dismiss() }
      }
      .padding(8)
      Divider()
      ZStack {
        Rectangle().fill(.background)
        if let frame = model.browserFrame {
          BrowserPage(frame: frame, say: say)
            .aspectRatio(frame.page, contentMode: .fit)
        } else {
          ProgressView()
        }
        if view.hidden {
          Label("Hidden from the agent", systemImage: "eye.slash")
            .font(.callout)
            .padding(8)
            .glassSurface(Capsule())
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(8)
            .allowsHitTesting(false)
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 900, idealWidth: 1100, minHeight: 640, idealHeight: 760)
    #endif
  }

  private func button(
    _ symbol: String, _ help: String, enabled: Bool? = nil, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol).frame(width: 26, height: 26)
    }
    .buttonStyle(.borderless)
    .disabled(!(enabled ?? view.open))
    .help(help)
  }
}

/// The page's frame, and the input over it: a point read against the
/// frame's size in CSS pixels.
private struct BrowserPage: View {
  let frame: BrowserFrame
  let say: BrowserIntents

  var body: some View {
    Image(decorative: frame.image, scale: 1)
      .resizable()
      .overlay { BrowserInput(page: frame.page, say: say) }
  }
}

/// The held keys as the page reads them: 1 Alt, 2 Ctrl, 4 Meta, 8 Shift.
private func pageModifiers(alt: Bool, control: Bool, meta: Bool, shift: Bool) -> Int64 {
  (alt ? 1 : 0) | (control ? 2 : 0) | (meta ? 4 : 0) | (shift ? 8 : 0)
}

#if os(macOS)
  private struct BrowserInput: NSViewRepresentable {
    let page: CGSize
    let say: BrowserIntents

    func makeNSView(context: Context) -> BrowserInputView { BrowserInputView(say: say) }

    func updateNSView(_ view: BrowserInputView, context: Context) { view.page = page }
  }

  /// The mouse, the wheel and every key, to the page while the view has
  /// focus — Tab, Escape and the shortcuts included, which would otherwise
  /// move focus, close the sheet or reach the menu bar.
  final class BrowserInputView: NSView {
    let say: BrowserIntents
    var page = CGSize(width: 1, height: 1)

    init(say: BrowserIntents) {
      self.say = say
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(
        NSTrackingArea(
          rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func point(_ event: NSEvent) -> CGPoint {
      let local = convert(event.locationInWindow, from: nil)
      guard bounds.width > 0, bounds.height > 0 else { return .zero }
      return CGPoint(
        x: local.x / bounds.width * page.width, y: local.y / bounds.height * page.height)
    }

    private func modifiers(_ event: NSEvent) -> Int64 {
      let flags = event.modifierFlags
      return pageModifiers(
        alt: flags.contains(.option), control: flags.contains(.control),
        meta: flags.contains(.command), shift: flags.contains(.shift))
    }

    private func send(
      _ action: BrowserPointerAction, _ event: NSEvent, button: String, buttons: Int64,
      clicks: Int64 = 0, dx: Double = 0, dy: Double = 0
    ) {
      let at = point(event)
      say.pointer(
        action: action, x: at.x, y: at.y, button: button, buttons: buttons, clickCount: clicks,
        deltaX: dx, deltaY: dy, modifiers: modifiers(event)
      ) { _ in }
    }

    override func mouseMoved(with event: NSEvent) {
      send(.move, event, button: "none", buttons: 0)
    }

    override func mouseDragged(with event: NSEvent) {
      send(.move, event, button: "left", buttons: 1)
    }

    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      send(.down, event, button: "left", buttons: 1, clicks: Int64(event.clickCount))
    }

    override func mouseUp(with event: NSEvent) {
      send(.up, event, button: "left", buttons: 0, clicks: Int64(event.clickCount))
    }

    override func otherMouseDown(with event: NSEvent) {
      send(.down, event, button: "middle", buttons: 4, clicks: Int64(event.clickCount))
    }

    override func otherMouseUp(with event: NSEvent) {
      send(.up, event, button: "middle", buttons: 0, clicks: Int64(event.clickCount))
    }

    override func scrollWheel(with event: NSEvent) {
      let scale: Double = event.hasPreciseScrollingDeltas ? 1 : 10
      send(
        .wheel, event, button: "none", buttons: 0, dx: -event.scrollingDeltaX * scale,
        dy: -event.scrollingDeltaY * scale)
    }

    /// What the page's own menu would offer for editing, against the user's
    /// clipboard: Chrome draws its menu nowhere the frames could show it.
    override func menu(for event: NSEvent) -> NSMenu? {
      let menu = NSMenu()
      for (title, action) in [
        ("Cut", BrowserEdit.cut), ("Copy", .copy), ("Paste", .paste), ("Select All", .selectAll),
      ] {
        let item = NSMenuItem(title: title, action: #selector(edit(_:)), keyEquivalent: "")
        item.target = self
        item.tag = action.rawValue
        menu.addItem(item)
      }
      return menu
    }

    @objc private func edit(_ item: NSMenuItem) {
      guard let action = BrowserEdit(rawValue: item.tag) else { return }
      say.edit(action: action) { _ in }
    }

    override func keyDown(with event: NSEvent) {
      say.key(
        down: true, keyCode: Int64(event.keyCode), characters: event.characters,
        modifiers: modifiers(event)
      ) { _ in }
    }

    override func keyUp(with event: NSEvent) {
      say.key(
        down: false, keyCode: Int64(event.keyCode), characters: event.characters,
        modifiers: modifiers(event)
      ) { _ in }
    }

    /// The shortcuts reach here before the menu bar, while this has focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      guard window?.firstResponder === self, event.type == .keyDown else {
        return super.performKeyEquivalent(with: event)
      }
      keyDown(with: event)
      return true
    }
  }
#else
  private struct BrowserInput: UIViewRepresentable {
    let page: CGSize
    let say: BrowserIntents

    func makeUIView(context: Context) -> BrowserInputView { BrowserInputView(say: say) }

    func updateUIView(_ view: BrowserInputView, context: Context) { view.page = page }
  }

  /// A finger on the page: a tap is a click and a drag scrolls it, as on a
  /// phone's own browser; a hardware keyboard's keys go to it while it has
  /// focus.
  final class BrowserInputView: UIView {
    let say: BrowserIntents
    var page = CGSize(width: 1, height: 1)
    private var last: CGPoint?

    init(say: BrowserIntents) {
      self.say = say
      super.init(frame: .zero)
      addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
      addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var canBecomeFirstResponder: Bool { true }

    private func toPage(_ point: CGPoint) -> CGPoint {
      guard bounds.width > 0, bounds.height > 0 else { return .zero }
      return CGPoint(
        x: point.x / bounds.width * page.width, y: point.y / bounds.height * page.height)
    }

    private func pointer(
      _ action: BrowserPointerAction, _ at: CGPoint, button: String, buttons: Int64,
      clicks: Int64 = 0, dx: Double = 0, dy: Double = 0
    ) {
      say.pointer(
        action: action, x: at.x, y: at.y, button: button, buttons: buttons, clickCount: clicks,
        deltaX: dx, deltaY: dy, modifiers: 0
      ) { _ in }
    }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
      becomeFirstResponder()
      let at = toPage(gesture.location(in: self))
      pointer(.move, at, button: "none", buttons: 0)
      pointer(.down, at, button: "left", buttons: 1, clicks: 1)
      pointer(.up, at, button: "left", buttons: 0, clicks: 1)
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
      let now = gesture.location(in: self)
      defer { last = gesture.state == .ended || gesture.state == .cancelled ? nil : now }
      guard let last else { return }
      let scale = bounds.width > 0 ? page.width / bounds.width : 1
      pointer(
        .wheel, toPage(now), button: "none", buttons: 0, dx: -(now.x - last.x) * scale,
        dy: -(now.y - last.y) * scale)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      guard send(presses, down: true) else { return super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      guard send(presses, down: false) else { return super.pressesEnded(presses, with: event) }
    }

    private func send(_ presses: Set<UIPress>, down: Bool) -> Bool {
      var sent = false
      for press in presses {
        guard let key = press.key else { continue }
        let flags = key.modifierFlags
        say.key(
          down: down, keyCode: Int64(key.keyCode.rawValue), characters: key.characters,
          modifiers: pageModifiers(
            alt: flags.contains(.alternate), control: flags.contains(.control),
            meta: flags.contains(.command), shift: flags.contains(.shift))
        ) { _ in }
        sent = true
      }
      return sent
    }
  }
#endif
