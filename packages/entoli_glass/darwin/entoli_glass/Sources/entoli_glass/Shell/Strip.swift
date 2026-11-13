import SwiftUI

/// A row of choices as the system draws a small control: each a glass
/// button of its own in one glass group, the picked ones tinted: a message's
/// reactions in the native conversation.
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
