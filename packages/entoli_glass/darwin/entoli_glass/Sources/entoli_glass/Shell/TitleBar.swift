import SwiftUI

/// A title bar: the window's title, the line under it, a way back where
/// there is somewhere to go back to, and its buttons. Whatever is in front
/// draws through this one view — the chat's bar and every Flutter page's —
/// so they are the system's bar alike, and a press goes to whichever bar's
/// [intents] it was drawn with. See `TitleBarSnapshot`.
///
/// A bar Dart gives no leading control of its own leads with [sidebar] where
/// the split view is one column — the Flutter app's menu button on a phone,
/// drawn the system's way — in place of the split view's chevron, which the
/// Flutter app has nothing like and which made the new-chat screen look like
/// a page pushed over the list.
struct TitleBar: ViewModifier {
  let bar: TitleBarSnapshot
  let intents: TitleBarIntents
  let sidebar: (() -> Void)?

  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var width
  #endif

  /// What leads the bar where Dart says nothing does.
  private var showSidebar: (() -> Void)? {
    #if os(iOS)
      bar.leading == nil && width == .compact ? sidebar : nil
    #else
      nil
    #endif
  }

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
        .navigationBarBackButtonHidden(bar.leading != nil || showSidebar != nil)
      #endif
      .toolbar { TitleBarContent(bar: bar, intents: intents, sidebar: showSidebar) }
  }
}

extension View {
  func titleBar(
    _ bar: TitleBarSnapshot, intents: TitleBarIntents, sidebar: (() -> Void)? = nil
  ) -> some View {
    modifier(TitleBar(bar: bar, intents: intents, sidebar: sidebar))
  }
}

extension TitleBarSnapshot {
  /// The chat's, before Dart has said what it is.
  static let initial = TitleBarSnapshot(present: true, title: "Entoli", subtitle: "", items: [])

  /// No page's bar: the window keeps the chat's title.
  static let absent = TitleBarSnapshot(present: false, title: "", subtitle: "", items: [])

  var expires: Date? { expiresAt.map { Date(timeIntervalSince1970: Double($0) / 1000) } }

  /// The title alone, with nothing to press.
  var bare: TitleBarSnapshot {
    var bar = self
    bar.leading = nil
    bar.items = []
    return bar
  }
}

extension TitleBarItem: Identifiable {}
extension TitleBarMenuItem: Identifiable {}

private struct TitleBarContent: ToolbarContent {
  let bar: TitleBarSnapshot
  let intents: TitleBarIntents
  let sidebar: (() -> Void)?

  private var buttons: [TitleBarItem] {
    bar.items.filter { !$0.spinner && $0.style != .confirm }
  }

  var body: some ToolbarContent {
    if let leading = bar.leading {
      ToolbarItem(placement: .navigation) {
        Button {
          intents.back { _ in }
        } label: {
          switch leading {
          case .back: Label("Back", systemImage: "chevron.backward")
          case .close: Label("Discard", systemImage: "xmark")
          }
        }
        .help(leading == .back ? "Back" : "Discard")
      }
    } else if let sidebar {
      ToolbarItem(placement: .navigation) {
        Button(action: sidebar) {
          Label("Chats", systemImage: "sidebar.leading")
        }
        .help("Show chats")
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
          TitleBarButton(item: item, intents: intents)
        }
      }
    }
    // The tick: the system's confirm, where its bars put one.
    if let tick = bar.items.first(where: { $0.style == .confirm }) {
      ToolbarItem(placement: Self.confirm) {
        TitleBarButton(item: tick, intents: intents)
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
  let item: TitleBarItem
  let intents: TitleBarIntents

  private func press(_ id: String) { intents.press(id: id) { _ in } }

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
              if let symbol = choice.checked ? "checkmark" : choice.symbol {
                Label(choice.label, systemImage: symbol)
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
private func subtitle(_ bar: TitleBarSnapshot) -> Text {
  guard let expires = bar.expires else { return Text(bar.subtitle) }
  let lead = bar.subtitle.isEmpty ? Text("") : Text("\(bar.subtitle) · ")
  return lead + Text("Expires in ") + Text(expires, style: .relative)
}
