import SwiftUI

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// A Bot Avatar drawn by the client from what the core sends: its slices
/// once, then a frame for each moment it is asked for. The motion is the
/// core's (`BotStage`, over the same engine the Flutter app draws); this only
/// paints. Live, it asks for a frame each display frame while on screen; a
/// still asks once, and is live for as long as a tap's reaction plays.
struct BotFaceView: View {
  let model: SettingsModel
  let key: String
  let colour: Int
  var size: CGFloat = 36
  var mood: Int = 0
  var live = true
  var thumbnail = false
  var turnable = false
  var reactToTap = false

  @StateObject private var driver = BotFaceDriver()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var moving: Bool { !reduceMotion && !thumbnail && (live || driver.reacting) }

  var body: some View {
    // Drawn when a frame lands; the timeline only asks for the next, so the
    // canvas is not drawn a second time on the tick with the frame it has.
    Canvas { context, canvas in
      guard let geometry = driver.geometry, let frame = driver.frame else { return }
      BotFacePainter.draw(
        frame, geometry, in: &context, size: canvas,
        colour: Color(rgb: colour), outline: Color.secondary.opacity(0.55))
    }
    .background {
      TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moving)) { timeline in
        Color.clear.onChange(of: timeline.date) { _, date in ask(at: date) }
      }
    }
    .frame(width: size, height: size)
    .background {
      // Where the face is in its window, for the pointer it follows.
      GeometryReader { geometry in
        Color.clear
          .onAppear { driver.frameInWindow = geometry.frame(in: .global) }
          .onChange(of: geometry.frame(in: .global)) { _, frame in driver.frameInWindow = frame }
      }
    }
    .contentShape(Rectangle())
    .gesture(turnable ? drag : nil)
    .onTapGesture(count: 2) {
      guard turnable else { return }
      driver.turn = (0, 0)
      ask(at: .now)
    }
    .onTapGesture {
      guard reactToTap, !reduceMotion else { return }
      model.say.botTap(instance: driver.instance, nowMs: driver.ms(.now), completion: ignore)
      driver.reacting = true
      ask(at: .now)
    }
    .task(id: "\(key)/\(mood)/\(live)/\(thumbnail)") {
      driver.geometry = await BotGeometry.of(key, model: model)
      ask(at: .now)
    }
    .onDisappear {
      model.say.botDrop(instance: driver.instance, completion: ignore)
    }
    // A face that neither turns nor reacts takes no clicks, which reach what
    // holds it: a thumbnail's button.
    .allowsHitTesting(turnable || reactToTap)
    .accessibilityHidden(true)
  }

  private var drag: some Gesture {
    DragGesture(minimumDistance: 2)
      .onChanged { value in
        if driver.dragFrom == nil { driver.dragFrom = driver.turn }
        let from = driver.dragFrom ?? (0, 0)
        driver.turn = (
          from.0 + value.translation.width * 0.011,
          min(0.9, max(-0.9, from.1 - value.translation.height * 0.009))
        )
        if !moving { ask(at: .now) }
      }
      .onEnded { _ in driver.dragFrom = nil }
  }

  private func ask(at date: Date) {
    guard !driver.asking else { return }
    driver.asking = true
    let ms = driver.ms(date)
    let pointer = moving ? driver.pointer() : nil
    model.say.botFrame(
      instance: driver.instance, key: key, mood: Int64(mood), live: !reduceMotion && live,
      thumbnail: thumbnail, nowMs: ms, turnYaw: driver.turn.0, turnPitch: driver.turn.1,
      pointerX: pointer.map { Double($0.x) }, pointerY: pointer.map { Double($0.y) },
      size: Double(size)
    ) { result in
      Task { @MainActor in
        driver.asking = false
        guard let numbers = try? result.get() else { return }
        let frame = BotFrame(numbers.doubles)
        driver.frame = frame
        if driver.reacting != frame.reacting { driver.reacting = frame.reacting }
      }
    }
  }
}

/// One avatar's own state on the client: who it is to the core, its clock,
/// the drag's turn, and the last frame and slices it was sent.
@MainActor
final class BotFaceDriver: ObservableObject {
  let instance = UUID().uuidString
  private let start = Date()
  @Published var frame: BotFrame?
  @Published var geometry: [BotSlice]?
  @Published var reacting = false
  var asking = false
  var turn: (CGFloat, CGFloat) = (0, 0)
  var dragFrom: (CGFloat, CGFloat)?
  var frameInWindow: CGRect = .zero

  /// Where the mouse is over this face's box, from its top left, while it is
  /// in the window: what a live face looks toward, wherever the mouse is in
  /// the window, as the Flutter app's do. None on a touch screen.
  func pointer() -> CGPoint? {
    #if os(macOS)
      guard let window = NSApp.keyWindow, let content = window.contentView else { return nil }
      let at = window.mouseLocationOutsideOfEventStream
      guard content.bounds.contains(at) else { return nil }
      // AppKit counts up from the bottom; SwiftUI's frame down from the top.
      let fromTop = content.bounds.height - at.y
      return CGPoint(x: at.x - frameInWindow.minX, y: fromTop - frameInWindow.minY)
    #else
      return nil
    #endif
  }

  /// Milliseconds into this avatar's clock.
  func ms(_ date: Date) -> Double { date.timeIntervalSince(start) * 1000 }
}

/// One cross-section: its loops as a path in the 0..100 box.
struct BotSlice {
  let path: Path
  let evenOdd: Bool
}

/// Each avatar's slices, fetched once and kept: a frame names them by place.
@MainActor
enum BotGeometry {
  private static var cache: [String: [BotSlice]] = [:]

  static func of(_ key: String, model: SettingsModel) async -> [BotSlice]? {
    if let hit = cache[key] { return hit }
    let numbers = await reply(or: nil) { model.say.botGeometry(key: key, completion: $0) }?
      .doubles
    guard let numbers else { return nil }
    let slices = decode(numbers)
    cache[key] = slices
    return slices
  }

  /// `BotStage.geometry`'s layout.
  static func decode(_ n: [Double]) -> [BotSlice] {
    var i = 0
    func next() -> Double {
      defer { i += 1 }
      return i < n.count ? n[i] : 0
    }
    var slices: [BotSlice] = []
    for _ in 0..<Int(next()) {
      let evenOdd = next() == 1
      var path = Path()
      for _ in 0..<Int(next()) {
        let points = Int(next())
        for p in 0..<points {
          let point = CGPoint(x: next(), y: next())
          if p == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
      }
      slices.append(BotSlice(path: path, evenOdd: evenOdd))
    }
    return slices
  }
}

/// One frame as the core sent it (`encodeFrame`): whether a reaction plays,
/// the root matrix, and the shapes back to front.
struct BotFrame {
  enum Shape {
    case slice(Int)
    case pill(CGRect, CGFloat)
    case arc(x0: CGFloat, x1: CGFloat, y: CGFloat, cx: CGFloat, cy: CGFloat, width: CGFloat)
  }

  let reacting: Bool
  let root: CGAffineTransform
  let shapes: [(Shape, CGAffineTransform)]

  init(_ n: [Double]) {
    var i = 0
    func next() -> CGFloat {
      defer { i += 1 }
      return i < n.count ? CGFloat(n[i]) : 0
    }
    func affine() -> CGAffineTransform {
      CGAffineTransform(a: next(), b: next(), c: next(), d: next(), tx: next(), ty: next())
    }
    reacting = next() == 1
    root = affine()
    var shapes: [(Shape, CGAffineTransform)] = []
    for _ in 0..<Int(next()) {
      let kind = Int(next())
      let p = (next(), next(), next(), next(), next(), next())
      let shape: Shape
      switch kind {
      case 0: shape = .slice(Int(p.0))
      case 1: shape = .pill(CGRect(x: p.0, y: p.1, width: p.2, height: p.3), p.4)
      default: shape = .arc(x0: p.0, x1: p.1, y: p.2, cx: p.3, cy: p.4, width: p.5)
      }
      shapes.append((shape, affine()))
    }
    self.shapes = shapes
  }
}

enum BotFacePainter {
  /// The eyes' near-black, the reference's.
  static let ink = Color(rgb: 0x151515)

  /// [frame] into a [size] canvas: the body's silhouette first in [outline],
  /// stroked a hair wide on screen, then every shape over it back to front,
  /// so the whole shape has one thin edge and its slices none between them.
  static func draw(
    _ frame: BotFrame, _ slices: [BotSlice], in context: inout GraphicsContext, size: CGSize,
    colour: Color, outline: Color
  ) {
    let box = CGAffineTransform(scaleX: size.width / 100, y: size.height / 100)
    let edge = min(1.4, max(0.6, min(size.width, size.height) * 0.02))
    func place(_ m: CGAffineTransform) -> CGAffineTransform {
      m.concatenating(frame.root).concatenating(box)
    }
    for (shape, matrix) in frame.shapes {
      guard case .slice(let index) = shape, slices.indices.contains(index) else { continue }
      context.stroke(
        slices[index].path.applying(place(matrix)), with: .color(outline), lineWidth: edge * 2)
    }
    for (shape, matrix) in frame.shapes {
      let m = place(matrix)
      switch shape {
      case .slice(let index):
        guard slices.indices.contains(index) else { continue }
        let slice = slices[index]
        context.fill(
          slice.path.applying(m), with: .color(colour), style: FillStyle(eoFill: slice.evenOdd))
      case .pill(let rect, let radius):
        context.fill(
          Path(roundedRect: rect, cornerRadius: radius).applying(m), with: .color(ink))
      case .arc(let x0, let x1, let y, let cx, let cy, let width):
        var arc = Path()
        arc.move(to: CGPoint(x: x0, y: y))
        arc.addQuadCurve(to: CGPoint(x: x1, y: y), control: CGPoint(x: cx, y: cy))
        // Stroked in the shape's own plane, then placed, so the stroke
        // narrows with the face as it turns.
        let stroked = arc.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round))
        context.fill(stroked.applying(m), with: .color(ink))
      }
    }
  }
}

extension Color {
  /// A colour from 0xRRGGBB.
  init(rgb: Int) { self.init(argb: 0xFF00_0000 | Int64(rgb & 0xFF_FFFF)) }
}

extension FlutterStandardTypedData {
  /// A Float64List's numbers.
  var doubles: [Double] {
    data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
  }
}
