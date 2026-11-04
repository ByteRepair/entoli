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

  /// Which column an iPhone shows: the list until a chat or a new one is
  /// asked for, and the list again on the way back.
  @State private var compactColumn = NavigationSplitViewColumn.sidebar

  private func visibility(_ shown: Bool) -> NavigationSplitViewVisibility {
    shown ? .all : .detailOnly
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
      SidebarView(model: model)
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
    } detail: {
      GeometryReader { proxy in
        FlutterCanvas(flutter: flutter) {
          StripLayer(model: model)
        }
        .onChange(of: proxy.safeAreaInsets, initial: true) { _, insets in
          model.insets(EdgeInsets(top: insets.top, leading: 0, bottom: insets.bottom, trailing: 0))
        }
      }
      #if os(iOS)
        // The insets Dart is told are the bars', not the keyboard's: Flutter
        // hears of the keyboard itself, and counted here too it would be
        // twice, the conversation pushed up under the toolbar.
        .ignoresSafeArea(.keyboard)
      #endif
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
      .windowBar(model)
    }
    // Voice mode over everything: the sidebar too, as the Flutter page was
    // pushed over the whole window.
    .overlay {
      if model.voice.present {
        VoiceView(model: model).transition(.opacity)
      }
    }
    .animation(.smooth(duration: 0.3), value: model.voice.present)
    // The palette over everything but voice mode, which has no palette to
    // switch from. Keyed on its opening, so each starts afresh.
    .overlay {
      if model.palette.open && !model.voice.present {
        PaletteView(model: model)
          .id(model.palette.serial)
          .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
      }
    }
    .animation(.snappy(duration: 0.2), value: model.palette.open)
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
    .onChange(of: model.detailAsked) { compactColumn = .detail }
    .onChange(of: columns) { _, columns in
      let shown = columns != .detailOnly
      if shown != model.window.sidebarShown { model.say.window.sidebarShown(shown: shown) { _ in } }
    }
  }
}

/// The Flutter view, and every layer drawn in its coordinates over it — the
/// anchor of a popover from a button in a message, and whatever comes next.
/// One container, so what the layers share is said once: the view runs under
/// the toolbar and the composer, which it scrolls beneath, and never under
/// the sidebar, which on 26 floats over the detail; and a layer is laid out
/// over exactly the view's frame, so a point Dart names is the same point
/// here. What floats over everything — a popover — is the system's
/// presentation, in a window of its own, rather than something drawn here.
struct FlutterCanvas<Layers: View>: View {
  let flutter: PlatformViewController
  @ViewBuilder var layers: Layers

  /// The edges the view and its layers run under.
  static var edges: Edge.Set { [.top, .bottom] }

  var body: some View {
    ZStack(alignment: .topLeading) {
      FlutterPane(controller: flutter)
        .ignoresSafeArea(edges: Self.edges)
      layers
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(edges: Self.edges)
    }
    .ignoresSafeArea(edges: Self.edges)
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
  /// The window's title bar: the chat's, or the Flutter page's over it — a
  /// way back and the page's own buttons in place of the chat's. A page with
  /// no bar of its own leaves the chat's title standing and nothing to press.
  fileprivate func windowBar(_ model: ShellModel) -> some View {
    let page = model.window.covered
    let bar =
      !page ? model.chatBar : model.pageBar.present ? model.pageBar : model.chatBar.bare
    return self
      .titleBar(bar, intents: page ? model.say.pageBar : model.say.chatBar)
      #if os(iOS)
        // A page whose bar Flutter still draws has it alone: one on screen.
        .toolbar(page && !model.pageBar.present ? .hidden : .automatic, for: .navigationBar)
      #endif
  }
}
