import SwiftUI

/// A strip of choices Dart asked for over the Flutter view — a message's
/// reactions — where in the view, what to offer and which are picked. Dart
/// waits on the answer: the index picked, or nil for a strip dismissed.
struct StripRequest: Identifiable, Equatable {
  struct Choice: Equatable {
    var glyph: String
    var name: String
    var chosen: Bool
  }

  let id = UUID()

  /// What opened it, in the Flutter view's coordinates.
  var anchor: CGRect
  var choices: [Choice]

  static func == (a: StripRequest, b: StripRequest) -> Bool { a.id == b.id }
}

extension ShellModel {
  /// Show a strip, answering the one already open as dismissed.
  func showStrip(_ args: [String: Any], reply: @escaping (Any?) -> Void) {
    answerStrip(nil)
    func number(_ key: String) -> CGFloat { CGFloat((args[key] as? NSNumber)?.doubleValue ?? 0) }
    let choices = (args["choices"] as? [[String: Any]] ?? []).map {
      StripRequest.Choice(
        glyph: $0["glyph"] as? String ?? "", name: $0["name"] as? String ?? "",
        chosen: $0["chosen"] as? Bool ?? false)
    }
    stripReply = reply
    strip = StripRequest(
      anchor: CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height")),
      choices: choices)
  }

  /// Tell Dart what was picked, or nil, and take the strip down.
  func answerStrip(_ index: Int?) {
    let reply = stripReply
    stripReply = nil
    strip = nil
    reply?(index.map { NSNumber(value: $0) } ?? nil)
  }
}

/// The strip over the Flutter view: a capsule of the system's glass just
/// above what opened it, centred on it and kept inside the view, each choice
/// a glass button of its own. A click anywhere else, or Escape, dismisses it.
struct StripLayer: View {
  @ObservedObject var model: ShellModel
  @Namespace private var glass

  private static let button: CGFloat = 40

  var body: some View {
    GeometryReader { box in
      if let strip = model.strip {
        ZStack(alignment: .topLeading) {
          Color.clear
            .contentShape(Rectangle())
            .onTapGesture { model.answerStrip(nil) }
          capsule(strip)
            .position(position(of: strip, in: box.size))
            .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
        }
        #if os(macOS)
          .onExitCommand { model.answerStrip(nil) }
        #endif
      }
    }
    .ignoresSafeArea()
    .animation(.snappy(duration: 0.18), value: model.strip)
  }

  private func width(of strip: StripRequest) -> CGFloat {
    CGFloat(strip.choices.count) * (Self.button + 4) + 8
  }

  /// Centred over the anchor and a little above it, held inside the view.
  private func position(of strip: StripRequest, in size: CGSize) -> CGPoint {
    let half = width(of: strip) / 2
    let height = Self.button + 8
    let x = min(max(strip.anchor.midX, half + 8), size.width - half - 8)
    let above = strip.anchor.minY - 6 - height / 2
    let y = above > height / 2 + 8 ? above : strip.anchor.maxY + 6 + height / 2
    return CGPoint(x: x, y: y)
  }

  private func capsule(_ strip: StripRequest) -> some View {
    GlassGroup(spacing: 4) {
      HStack(spacing: 4) {
        ForEach(Array(strip.choices.enumerated()), id: \.offset) { i, choice in
          Button {
            model.answerStrip(i)
          } label: {
            Text(choice.glyph)
              .font(.system(size: 22))
              .frame(width: Self.button, height: Self.button)
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .modifier(StripChoice(id: "\(i)", glass: glass, chosen: choice.chosen))
          .help(choice.name)
          .accessibilityLabel(choice.name)
        }
      }
      .padding(4)
      .glassSurface(Capsule())
    }
    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
  }
}

/// A choice's own glass: interactive, so it answers the pointer as the
/// system's controls do, and tinted where it is already picked.
private struct StripChoice: ViewModifier {
  let id: String
  let glass: Namespace.ID
  let chosen: Bool

  func body(content: Content) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      content.glassControl(id, in: glass, shape: Circle(), tint: chosen ? .accentColor : nil)
    } else if chosen {
      content.background(Color.accentColor.opacity(0.3), in: Circle())
    } else {
      content
    }
  }
}
