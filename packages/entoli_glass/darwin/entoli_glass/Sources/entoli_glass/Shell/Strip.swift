import SwiftUI

/// A strip of choices Dart asked for over the Flutter view — a message's
/// reactions — where in the view, what to offer and which are picked. Dart
/// waits on the answer: the index picked, or nil for a strip dismissed.
struct StripRequest: Identifiable, Equatable {
  let id = UUID()

  /// What opened it, in the Flutter view's coordinates.
  var anchor: CGRect
  var choices: [StripOption]

  static func == (a: StripRequest, b: StripRequest) -> Bool { a.id == b.id }
}

extension ShellModel {
  /// Show a strip, answering the one already open as dismissed.
  func showStrip(_ request: ChoiceStrip, reply: @escaping (Int64?) -> Void) {
    answerStrip(nil)
    stripReply = reply
    strip = StripRequest(
      anchor: CGRect(x: request.x, y: request.y, width: request.width, height: request.height),
      choices: request.options)
  }

  /// Tell Dart what was picked, or nil, and take the strip down.
  func answerStrip(_ index: Int?) {
    let reply = stripReply
    stripReply = nil
    strip = nil
    reply?(index.map(Int64.init))
  }
}

/// The strip over the Flutter view, as the system presents a small control
/// anchored on content: a popover from what opened it, in the system's glass
/// and its own window, so it is clipped by nothing and sits over the sidebar
/// or the toolbar where that is where the room is. Its placement, its arrow,
/// and its dismissal — a click elsewhere, Escape — are the popover's. Each
/// choice is a glass button of its own.
///
/// A layer of `FlutterCanvas`, which gives it the view's frame, so the anchor
/// Dart sends is a rect in this view. It takes no clicks itself.
struct StripLayer: View {
  var model: ShellModel

  /// The popover's own dismissal is the strip dismissed; a pick has already
  /// answered and cleared it.
  private var shown: Binding<StripRequest?> {
    Binding(
      get: { model.strip },
      set: { if $0 == nil { model.answerStrip(nil) } })
  }

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .popover(
        item: shown,
        attachmentAnchor: .rect(.rect(model.strip?.anchor ?? .zero)),
        arrowEdge: .top
      ) { strip in
        choices(strip)
          // A popover on an iPhone too, not the sheet it would become.
          .presentationCompactAdaptation(.popover)
      }
  }

  private func choices(_ strip: StripRequest) -> some View {
    GlassChoices(
      choices: strip.choices.map { ($0.glyph, $0.name, $0.chosen) },
      pick: { model.answerStrip($0) })
  }
}

/// A row of choices as the system draws a small control: each a glass
/// button of its own in one glass group, the picked ones tinted. What a
/// strip shows, and a message's reactions in the native conversation.
struct GlassChoices: View {
  let choices: [(glyph: String, name: String, chosen: Bool)]
  let pick: (Int) -> Void
  @Namespace private var glass

  private static let button: CGFloat = 40

  var body: some View {
    GlassGroup(spacing: 4) {
      HStack(spacing: 4) {
        ForEach(Array(choices.enumerated()), id: \.offset) { i, choice in
          Button {
            pick(i)
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
      .padding(6)
    }
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
