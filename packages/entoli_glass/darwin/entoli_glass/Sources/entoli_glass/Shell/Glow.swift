import SwiftUI

/// What the glow is doing, one look per thing voice mode can be doing, each
/// to be told apart across a room.
enum GlowMode: Equatable {
  /// The microphone shut and nothing said: dim and still, and nothing
  /// redrawing it.
  case still
  /// Loading the models: a slow, faint drift.
  case starting
  /// Listening: drifting, and swelling with the microphone.
  case listening
  /// A turn running: the light orbits.
  case thinking
  /// The reply read out: the light beats in the reply's colour.
  case speaking
}

/// The microphone's level, read by the glow on each frame rather than
/// observed: it moves many times a second, and only the glow draws it.
final class VoiceLevel {
  private(set) var raw: Double = 0
  private var smoothed: Double = 0
  private var at: TimeInterval = 0

  func set(_ level: Double) { raw = min(max(level, 0), 1) }

  /// Eased toward the latest level, quicker up than down, so the glow
  /// swells with a word and settles after it rather than flickering.
  func eased(at time: TimeInterval) -> Double {
    let dt = min(max(time - at, 0), 0.1)
    at = time
    let rate = raw > smoothed ? 14.0 : 4.0
    smoothed += (raw - smoothed) * min(dt * rate, 1)
    return smoothed
  }
}

/// Voice mode's light: a mesh of the two voices' colours whose points drift
/// slowly while idle, swell with the microphone while listening, orbit while a
/// turn runs, and beat while the reply is read out, faded to a soft disc.
/// A `MeshGradient`, blurred.
struct VoiceGlow: View {
  let mode: GlowMode
  let heard: Color
  let spoken: Color
  let level: VoiceLevel

  var body: some View {
    TimelineView(.animation(paused: mode == .still)) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      let loud = mode == .listening ? level.eased(at: t) : 0
      GeometryReader { box in
        let side = min(box.size.width, box.size.height)
        glow(t: t, loud: loud)
          .frame(width: side, height: side)
          .mask(
            RadialGradient(
              colors: [.black, .black.opacity(0.85), .clear],
              center: .center, startRadius: 0, endRadius: side / 2))
          .scaleEffect(scale(t: t, loud: loud))
          .opacity(mode == .still ? 0.35 : 1)
          .frame(width: box.size.width, height: box.size.height)
      }
    }
    .animation(.smooth(duration: 0.6), value: mode)
    .accessibilityHidden(true)
  }

  /// How big the light is: a breath under everything, the microphone's level
  /// on top while listening, a beat while speaking.
  private func scale(t: TimeInterval, loud: Double) -> CGFloat {
    let breath = sin(t * 2 * .pi / 1.9) * 0.025
    switch mode {
    case .still: return 0.78
    case .starting: return 0.8 + breath
    case .listening: return 0.84 + breath + loud * 0.32
    case .thinking: return 0.86 + breath
    case .speaking:
      // A beat rather than a wave: quick up, slow down.
      let phase = (t * 2.1).truncatingRemainder(dividingBy: 1)
      return 0.88 + pow(1 - phase, 3) * 0.08
    }
  }

  private func glow(t: TimeInterval, loud: Double) -> some View {
    MeshGradient(
      width: 3, height: 3, points: points(t: t, loud: loud), colors: colors(t: t),
      smoothsColors: true
    )
    .blur(radius: 18)
  }

  /// The mesh's nine points: the corners fixed, the edges and the middle
  /// wandering. Thinking turns the wandering into an orbit about the middle.
  private func points(t: TimeInterval, loud: Double) -> [SIMD2<Float>] {
    let speed: Double
    let reach: Double
    switch mode {
    case .still: (speed, reach) = (0, 0.02)
    case .starting: (speed, reach) = (0.25, 0.05)
    case .listening: (speed, reach) = (0.45, 0.07 + loud * 0.1)
    case .thinking: (speed, reach) = (1.4, 0.12)
    case .speaking: (speed, reach) = (0.8, 0.09)
    }
    var out: [SIMD2<Float>] = []
    for row in 0..<3 {
      for col in 0..<3 {
        let x = Double(col) / 2
        let y = Double(row) / 2
        let corner = (row != 1) && (col != 1)
        if corner {
          out.append(SIMD2(Float(x), Float(y)))
          continue
        }
        let seed = Double(row * 3 + col)
        var dx = sin(t * speed + seed * 1.7) * reach
        var dy = cos(t * speed * 0.8 + seed * 2.3) * reach
        if mode == .thinking {
          // An orbit: each point carried round the middle, out of step.
          let angle = t * speed + seed
          dx = cos(angle) * reach
          dy = sin(angle) * reach
        }
        // The edges stay on their edge, as the mesh needs them to.
        if row == 1 && col == 1 {
          out.append(SIMD2(Float(x + dx), Float(y + dy)))
        } else if row == 1 {
          out.append(SIMD2(Float(x), Float(y + dy)))
        } else {
          out.append(SIMD2(Float(x + dx), Float(y)))
        }
      }
    }
    return out
  }

  /// The two voices across the mesh: the heard one while listening, the
  /// spoken one while speaking, both turning through each other while a
  /// turn runs, grey while the microphone is shut.
  private func colors(t: TimeInterval) -> [Color] {
    switch mode {
    case .still:
      return Array(repeating: Color.gray.opacity(0.6), count: 9)
    case .speaking:
      return [
        spoken.opacity(0.5), spoken, heard.opacity(0.6),
        spoken, .white.opacity(0.9), spoken,
        heard.opacity(0.5), spoken, spoken.opacity(0.5),
      ]
    case .thinking:
      // Both voices, interleaved: the orbit carries them through each other.
      return [
        heard.opacity(0.5), spoken, heard.opacity(0.6),
        spoken, .white.opacity(0.7), heard,
        heard.opacity(0.6), spoken, spoken.opacity(0.5),
      ]
    case .starting, .listening:
      return [
        heard.opacity(0.4), heard, spoken.opacity(0.5),
        heard, .white.opacity(0.85), heard,
        spoken.opacity(0.4), heard, heard.opacity(0.4),
      ]
    }
  }
}
