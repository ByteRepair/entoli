import SwiftUI

/// The window: a split view whose sidebar is native and whose detail is the
/// Flutter view, the shell's chrome over it. The Flutter view fills the
/// detail, under the toolbar and the composer; how far those reach is the
/// safe area, which goes to Dart as padding.
struct ShellView: View {
  @ObservedObject var model: ShellModel
  let flutter: PlatformViewController

  /// The conversation's column in the Flutter view, which the composer is
  /// held to as the Flutter one is: `_readableWidth`, and the composer's own
  /// padding either side.
  static let readableWidth: CGFloat = 760

  /// The split view's own, so a change of it is animated whichever end made
  /// it: the system's button animates on its own, and a change Dart made — the
  /// View menu, its key — is put in an animation below. Dart is told of the
  /// first and is the source of the second.
  @State private var columns = NavigationSplitViewVisibility.all

  private func visibility(_ shown: Bool) -> NavigationSplitViewVisibility {
    shown ? .all : .detailOnly
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columns) {
      SidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
    } detail: {
      GeometryReader { proxy in
        FlutterPane(controller: flutter)
          // Under the toolbar and the composer, which it scrolls beneath;
          // never under the sidebar, which on 26 floats over the detail.
          .ignoresSafeArea(edges: [.top, .bottom])
          .onChange(of: proxy.safeAreaInsets, initial: true) { _, insets in
            model.insets(EdgeInsets(top: insets.top, leading: 0, bottom: insets.bottom, trailing: 0))
          }
      }
      // Over the Flutter view, which draws nothing there: the new-chat
      // screen, between the toolbar and the composer.
      .overlay {
        if model.newChat.present && !model.window.covered {
          NewChatView(model: model).transition(.opacity)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 0) {
          if !model.turn.isEmpty && !model.window.covered {
            TurnSurfaceView(model: model)
              .padding(.top, 6)
              .frame(maxWidth: ShellView.readableWidth + 16)
              .frame(maxWidth: .infinity)
              .transition(.opacity.combined(with: .move(edge: .bottom)))
          }
          ComposerSlot(composer: model.composer, covered: model.window.covered)
        }
        .animation(ComposerView.motion, value: model.turn.isEmpty)
      }
      .chatBar(model)
    }
    // Voice mode over everything: the sidebar too, as the Flutter page was
    // pushed over the whole window.
    .overlay {
      if model.voice.present {
        VoiceView(model: model).transition(.opacity)
      }
    }
    .animation(.smooth(duration: 0.3), value: model.voice.present)
    // Voice mode is the whole window: nothing of the toolbar's — the title,
    // the new chat and sidebar buttons — stands over it.
    #if os(macOS)
      .toolbar(model.voice.present ? .hidden : .automatic, for: .windowToolbar)
    #endif
    .preferredColorScheme(model.window.colorScheme)
    .onChange(of: model.window.sidebarShown, initial: true) { _, shown in
      guard visibility(shown) != columns else { return }
      withAnimation(.smooth(duration: 0.3)) { columns = visibility(shown) }
    }
    .onChange(of: columns) { _, columns in
      let shown = columns != .detailOnly
      if shown != model.window.sidebarShown { model.intent("sidebar", ["shown": shown]) }
    }
  }
}

/// The composer, where the page in front has one and no Flutter page covers
/// it. Its own view, observing the composer alone.
private struct ComposerSlot: View {
  @ObservedObject var composer: ComposerModel
  let covered: Bool

  var body: some View {
    if composer.present && !covered {
      ComposerView(model: composer)
        .frame(maxWidth: ShellView.readableWidth + 16)
        .frame(maxWidth: .infinity)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }
}

extension View {
  /// The window's title, what the chat's Flutter bar said under it, and its
  /// buttons; the buttons step aside while a Flutter page covers the chat,
  /// that page having a bar of its own.
  fileprivate func chatBar(_ model: ShellModel) -> some View {
    let bar = model.chatBar
    return self
      .navigationTitle(bar.title)
      #if os(macOS)
        .navigationSubtitle(subtitle(bar))
      #endif
      .toolbar {
        if !model.window.covered {
          // The spinner on its own, with no glass behind it: in the buttons'
          // group the system draws it as a control, a button that is not.
          if let spinner = bar.items.first(where: \.spinner) {
            Spinner(label: spinner.label)
          }
          ToolbarItemGroup(placement: .primaryAction) {
            ForEach(bar.items.filter { !$0.spinner }) { item in
              Button {
                model.intent("toolbar", ["id": item.id])
              } label: {
                Label(item.label, systemImage: item.symbol ?? "circle")
              }
              .help(item.label)
            }
          }
        }
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
private func subtitle(_ bar: ChatBarState) -> Text {
  guard let expires = bar.expires else { return Text(bar.subtitle) }
  let lead = bar.subtitle.isEmpty ? Text("") : Text("\(bar.subtitle) · ")
  return lead + Text("Expires in ") + Text(expires, style: .relative)
}
