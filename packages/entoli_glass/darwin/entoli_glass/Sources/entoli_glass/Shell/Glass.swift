import SwiftUI

// The system's glass where it has it, its materials before that. Nothing here
// draws a look of its own: each branch names what the OS provides, and the OS
// draws it as its own apps are drawn.

/// A button in the system's glass, or bordered where there is none.
struct GlassButton: ViewModifier {
  var prominent = false

  func body(content: Content) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      if prominent {
        content.buttonStyle(.glassProminent)
      } else {
        content.buttonStyle(.glass)
      }
    } else if prominent {
      content.buttonStyle(.borderedProminent)
    } else {
      content.buttonStyle(.bordered)
    }
  }
}

/// A surface in the system's glass, or its regular material where there is
/// none.
struct GlassSurface<S: Shape>: ViewModifier {
  var shape: S
  var tint: Color?

  func body(content: Content) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      content.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
    } else if let tint {
      content.background(tint.opacity(0.5), in: shape)
    } else {
      content.background(.regularMaterial, in: shape)
    }
  }
}

/// Glass that sits together blends together, the way a system toolbar's
/// controls do.
struct GlassGroup<Content: View>: View {
  var spacing: CGFloat = 8
  @ViewBuilder var content: Content

  var body: some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) { content }
    } else {
      content
    }
  }
}

/// One control of a glass group, by [id]: the system morphs it in and out of
/// its neighbours as it comes and goes, rather than popping it.
struct GlassControl<S: Shape>: ViewModifier {
  var id: String
  var namespace: Namespace.ID
  var shape: S
  var tint: Color?

  /// Whether the glass answers a touch itself, as a button's does. Not a
  /// field's: interactive glass takes the touch, and a field has to have it.
  var interactive = true

  func body(content: Content) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      let glass = tint.map { Glass.regular.tint($0) } ?? .regular
      content
        .glassEffect(interactive ? glass.interactive() : glass, in: shape)
        .glassEffectID(id, in: namespace)
    } else if let tint {
      content.background(tint, in: shape).foregroundStyle(.white)
    } else {
      content.background(.regularMaterial, in: shape)
    }
  }
}

extension View {
  func glassControl<S: Shape>(
    _ id: String, in namespace: Namespace.ID, shape: S, tint: Color? = nil,
    interactive: Bool = true
  ) -> some View {
    modifier(
      GlassControl(id: id, namespace: namespace, shape: shape, tint: tint, interactive: interactive))
  }

  func glassButton(prominent: Bool = false) -> some View {
    modifier(GlassButton(prominent: prominent))
  }

  func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil) -> some View {
    modifier(GlassSurface(shape: shape, tint: tint))
  }
}
