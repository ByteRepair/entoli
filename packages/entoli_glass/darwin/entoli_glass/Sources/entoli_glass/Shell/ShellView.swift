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

  private var columns: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: { model.window.sidebarShown ? .all : .detailOnly },
      set: { model.intent("sidebar", ["shown": $0 != .detailOnly]) })
  }

  var body: some View {
    NavigationSplitView(columnVisibility: columns) {
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
    .preferredColorScheme(model.window.colorScheme)
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
          ToolbarItemGroup(placement: .primaryAction) {
            ForEach(bar.items) { item in
              if item.spinner {
                ProgressView().controlSize(.small).help(item.label)
              } else {
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
}

/// The line under the title: the project and the pin, and a temporary chat's
/// countdown, which the system keeps counting.
private func subtitle(_ bar: ChatBarState) -> Text {
  guard let expires = bar.expires else { return Text(bar.subtitle) }
  let lead = bar.subtitle.isEmpty ? Text("") : Text("\(bar.subtitle) · ")
  return lead + Text("Expires in ") + Text(expires, style: .relative)
}
