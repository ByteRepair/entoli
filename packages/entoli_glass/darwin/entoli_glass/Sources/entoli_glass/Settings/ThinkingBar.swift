import SwiftUI

/// How hard something thinks, as a row of glass cells: the least on the left
/// and the most on the right. Each cell holds lines that flow, a few slow
/// curves in the first and a dense, quick weave in the last, and the cells up
/// to the one picked glow in the accent. A tap or a drag picks the nearest;
/// to VoiceOver it is an adjustable value. Still under Reduce Motion.
struct ThinkingBar: View {
  let labels: [String]
  let picked: Int
  let onPick: (Int) -> Void

  @Environment(\.accessibilityReduceMotion) private var still
  @State private var dragging: Int?

  private var shown: Int { dragging ?? picked }

  var body: some View {
    VStack(spacing: 8) {
      GeometryReader { geometry in
        TimelineView(.animation(paused: still)) { timeline in
          Canvas { context, size in
            draw(
              in: &context, size: size,
              time: still ? 0 : timeline.date.timeIntervalSinceReferenceDate)
          }
        }
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { dragging = index(at: $0.location.x, width: geometry.size.width) }
            .onEnded {
              let index = index(at: $0.location.x, width: geometry.size.width)
              dragging = nil
              if index != picked { onPick(index) }
            })
      }
      .frame(height: 40)
      HStack(spacing: 4) {
        ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
          Text(label)
            .font(.caption.weight(i == shown ? .semibold : .regular))
            .foregroundStyle(i == shown ? Color.accentColor : .secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { if i != picked { onPick(i) } }
        }
      }
    }
    .animation(.snappy(duration: 0.2), value: shown)
    .accessibilityElement(children: .ignore)
    .accessibilityValue(labels.indices.contains(picked) ? labels[picked] : "")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment where picked + 1 < labels.count: onPick(picked + 1)
      case .decrement where picked > 0: onPick(picked - 1)
      default: break
      }
    }
  }

  private func index(at x: CGFloat, width: CGFloat) -> Int {
    guard width > 0, !labels.isEmpty else { return 0 }
    return min(labels.count - 1, max(0, Int(x / width * CGFloat(labels.count))))
  }

  private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
    let count = labels.count
    guard count > 0 else { return }
    let gap: CGFloat = 4
    let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
    for i in 0..<count {
      let rect = CGRect(
        x: CGFloat(i) * (width + gap), y: 0, width: width, height: size.height)
      // The bar is one shape cut into cells: only its two ends are rounded.
      let r = min(10, size.height / 2)
      let lead: CGFloat = i == 0 ? r : 0
      let trail: CGFloat = i == count - 1 ? r : 0
      let cell = UnevenRoundedRectangle(
        topLeadingRadius: lead, bottomLeadingRadius: lead,
        bottomTrailingRadius: trail, topTrailingRadius: trail
      ).path(in: rect)
      // How hard this cell thinks, from barely to fully.
      let effort = count == 1 ? 1 : Double(i) / Double(count - 1)
      let lit = i <= shown
      let tint = Color.accentColor
      context.fill(
        cell,
        with: lit
          ? .linearGradient(
            Gradient(colors: [tint.opacity(0.10 + 0.14 * effort), tint.opacity(0.18 + 0.2 * effort)]),
            startPoint: CGPoint(x: rect.minX, y: rect.minY),
            endPoint: CGPoint(x: rect.maxX, y: rect.maxY))
          : .color(Color.primary.opacity(0.05)))
      var inside = context
      inside.clip(to: cell)
      let lines = 2 + Int((effort * 5).rounded())
      let spacing = rect.height / CGFloat(lines + 1)
      let frequency = 0.05 + 0.16 * effort
      let amplitude = 1.5 + 3.5 * effort
      let speed = 0.5 + 2.5 * effort
      for line in 0..<lines {
        let base = rect.minY + spacing * CGFloat(line + 1)
        let offset = Double(line) * 0.9
        var path = Path()
        var x = rect.minX
        while x <= rect.maxX + 2 {
          let u = Double(x)
          var y = sin(u * frequency + time * speed + offset)
          y += 0.6 * effort * sin(u * frequency * 2.7 - time * speed * 1.4 + offset * 1.7)
          y += 0.35 * effort * effort * sin(u * frequency * 5.3 + time * speed * 2.1 - offset)
          let point = CGPoint(x: x, y: base + CGFloat(y) * amplitude)
          if x == rect.minX { path.move(to: point) } else { path.addLine(to: point) }
          x += 2
        }
        inside.stroke(
          path,
          with: .color(lit ? tint.opacity(0.45 + 0.5 * effort) : Color.secondary.opacity(0.28)),
          lineWidth: lit ? 1.2 : 0.8)
      }
      context.stroke(
        cell, with: .color(lit ? tint.opacity(0.35) : Color.primary.opacity(0.08)), lineWidth: 0.5)
    }
  }
}
