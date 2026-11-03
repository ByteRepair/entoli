import SwiftUI

/// A title bar: the window's title, the line under it, a way back where
/// there is somewhere to go back to, and its buttons. Whatever is in front
/// draws through this one view — the chat's bar and every Flutter page's —
/// so they are the system's bar alike, and a press is said to Dart under
/// whichever concern [say] names. See `TitleBarSnapshot`.
struct TitleBar: ViewModifier {
  let bar: TitleBarState

  /// A press, or the way back, as an intent name and its args.
  let say: (_ name: String, _ args: [String: Any?]) -> Void

  func body(content: Content) -> some View {
    content
      .navigationTitle(bar.title)
      #if os(macOS)
        .navigationSubtitle(subtitle(bar))
      #else
        // A title sits in its bar, as Messages' does.
        .navigationBarTitleDisplayMode(.inline)
        // A page's way back is Dart's, which asks before it goes; the
        // split view's own would leave the page standing.
        .navigationBarBackButtonHidden(bar.leading != nil)
      #endif
      .toolbar { TitleBarContent(bar: bar, say: say) }
  }
}

extension View {
  func titleBar(
    _ bar: TitleBarState, say: @escaping (_ name: String, _ args: [String: Any?]) -> Void
  ) -> some View {
    modifier(TitleBar(bar: bar, say: say))
  }
}

/// `TitleBarSnapshot`: a chat's bar or a page's.
struct TitleBarState: Decodable, Equatable {
  /// False where no page has a bar: the window keeps the chat's title.
  var present = true
  var title = "Entoli"
  var subtitle = ""
  var expiresAt: Double?
  var leading: Leading?
  var items: [ToolbarItemState] = []

  enum Leading: String, Decodable { case back, close }

  var expires: Date? { expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

  /// The title alone, with nothing to press.
  var bare: TitleBarState {
    var bar = self
    bar.leading = nil
    bar.items = []
    return bar
  }
}

/// `ToolbarItem`.
struct ToolbarItemState: Decodable, Equatable, Identifiable {
  var id: String
  var label: String
  var symbol: String?
  var spinner = false
  var style = Style.icon
  var enabled = true
  var menu: [ToolbarMenuItemState] = []

  /// `ToolbarStyle`.
  enum Style: String, Decodable { case icon, text, prominent, confirm }
}

/// `ToolbarMenuItem`.
struct ToolbarMenuItemState: Decodable, Equatable, Identifiable {
  var id: String
  var label: String
  var hint: String?
  var checked = false
}

private struct TitleBarContent: ToolbarContent {
  let bar: TitleBarState
  let say: (_ name: String, _ args: [String: Any?]) -> Void

  private var buttons: [ToolbarItemState] {
    bar.items.filter { !$0.spinner && $0.style != .confirm }
  }

  var body: some ToolbarContent {
    if let leading = bar.leading {
      ToolbarItem(placement: .navigation) {
        Button {
          say("back", [:])
        } label: {
          switch leading {
          case .back: Label("Back", systemImage: "chevron.backward")
          case .close: Label("Discard", systemImage: "xmark")
          }
        }
        .help(leading == .back ? "Back" : "Discard")
      }
    }
    // The spinner on its own, with no glass behind it: in the buttons'
    // group the system draws it as a control, a button that is not.
    if let spinner = bar.items.first(where: \.spinner) {
      Spinner(label: spinner.label)
    }
    if !buttons.isEmpty {
      ToolbarItemGroup(placement: .primaryAction) {
        ForEach(buttons) { item in
          TitleBarButton(item: item, say: say)
        }
      }
    }
    // The tick: the system's confirm, where its bars put one.
    if let tick = bar.items.first(where: { $0.style == .confirm }) {
      ToolbarItem(placement: Self.confirm) {
        TitleBarButton(item: tick, say: say)
      }
    }
  }

  private static var confirm: ToolbarItemPlacement {
    #if os(macOS)
      // A window's toolbar has no confirm of its own; that is a sheet's.
      .primaryAction
    #else
      .confirmationAction
    #endif
  }
}

/// One of a bar's buttons, drawn as its style says.
private struct TitleBarButton: View {
  let item: ToolbarItemState
  let say: (_ name: String, _ args: [String: Any?]) -> Void

  private func press(_ id: String) { say("press", ["id": id]) }

  private var icon: some View {
    Label(item.label, systemImage: item.symbol ?? "circle")
  }

  var body: some View {
    Group {
      switch item.style {
      case .icon where !item.menu.isEmpty:
        Menu {
          ForEach(item.menu) { choice in
            Button {
              press(choice.id)
            } label: {
              if choice.checked {
                Label(choice.label, systemImage: "checkmark")
              } else {
                Text(choice.label)
              }
              if let hint = choice.hint { Text(hint) }
            }
          }
        } label: {
          icon
        }
      case .icon:
        Button { press(item.id) } label: { icon }
      case .text:
        Button(item.label) { press(item.id) }
      case .prominent:
        Button(item.label) { press(item.id) }.glassButton(prominent: true)
      case .confirm:
        confirm
      }
    }
    .help(item.label)
    .disabled(!item.enabled)
  }

  @ViewBuilder private var confirm: some View {
    let label = Label(item.label, systemImage: "checkmark")
    if #available(iOS 26.0, macOS 26.0, *) {
      Button(role: .confirm) { press(item.id) } label: { label }
        #if os(macOS)
          .buttonStyle(.glassProminent)
        #endif
    } else {
      Button { press(item.id) } label: { label }
    }
  }
}

/// A turn running, as the toolbar says it: a small spinner beside the
/// buttons, bare.
private struct Spinner: ToolbarContent {
  let label: String

  private var spinner: some View {
    ProgressView()
      .controlSize(.small)
      .frame(width: 20, height: 20)
      .help(label)
      .accessibilityLabel(label)
  }

  var body: some ToolbarContent {
    if #available(iOS 26.0, macOS 26.0, *) {
      ToolbarItem(placement: .primaryAction) { spinner }
        .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .primaryAction) { spinner }
    }
  }
}

/// The line under the title: the project and the pin, and a temporary chat's
/// countdown, which the system keeps counting.
private func subtitle(_ bar: TitleBarState) -> Text {
  guard let expires = bar.expires else { return Text(bar.subtitle) }
  let lead = bar.subtitle.isEmpty ? Text("") : Text("\(bar.subtitle) · ")
  return lead + Text("Expires in ") + Text(expires, style: .relative)
}
