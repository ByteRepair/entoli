import SwiftUI

/// The conversation's table of contents: a tick per prompt beside the
/// column, the one being read picked out, a fork where the turn has other
/// threads. A press selects, and so does every move while pressed, so a drag
/// along the rail scrubs from prompt to prompt; ticks close up to fit when
/// there are more than its height holds.
struct ChapterRail: View {
  let chapters: [ChapterSnapshot]
  let current: Int?
  let select: (ChapterSnapshot) -> Void

  private static let pitch: CGFloat = 18
  private static let leastPitch: CGFloat = 4
  static let width: CGFloat = 44

  @State private var hovered: Int?
  @State private var pressed: Int?

  var body: some View {
    if chapters.count > 1 {
      GeometryReader { proxy in
        let pitch = min(
          Self.pitch, max(Self.leastPitch, (proxy.size.height - 32) / CGFloat(chapters.count)))
        VStack(spacing: 0) {
          ForEach(Array(chapters.enumerated()), id: \.offset) { i, chapter in
            tick(chapter, at: i, pitch: pitch)
          }
        }
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0).onChanged { drag in
            let i = Int(drag.location.y / pitch)
            guard i >= 0, i < chapters.count, i != pressed else { return }
            pressed = i
            select(chapters[i])
          }
          .onEnded { _ in pressed = nil }
        )
        .frame(width: Self.width, height: proxy.size.height)
      }
      .frame(width: Self.width)
    }
  }

  private func tick(_ chapter: ChapterSnapshot, at i: Int, pitch: CGFloat) -> some View {
    let lit = current == i
    let hot = hovered == i
    return HStack(spacing: 4) {
      Spacer(minLength: 0)
      if chapter.threads > 1 {
        Image(systemName: "arrow.triangle.branch").font(.system(size: 8))
      }
      Capsule()
        .frame(width: lit || hot ? 18 : 12, height: 2)
    }
    .foregroundStyle(
      lit ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(hot ? 0.9 : 0.45))
    )
    .frame(height: pitch)
    .padding(.trailing, 12)
    .contentShape(Rectangle())
    .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
    .help(
      chapter.threads > 1
        ? "\(chapter.preview)\n\(chapter.threads) threads branch here" : chapter.preview)
  }
}
