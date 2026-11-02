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
      if shown != model.window.sidebarShown { model.intent("sidebar", ["shown": shown]) }
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
  /// The window's title, what the chat's Flutter bar said under it, and its
  /// buttons; the buttons step aside while a Flutter page covers the chat,
  /// that page having a bar of its own.
  fileprivate func chatBar(_ model: ShellModel) -> some View {
    let bar = model.chatBar
    return self
      .navigationTitle(bar.title)
      #if os(macOS)
        .navigationSubtitle(subtitle(bar))
      #else
        // A chat's title sits in its bar, as Messages' does.
        .navigationBarTitleDisplayMode(.inline)
        // A Flutter page over the chat has a bar and a back button of its
        // own: one of each on screen.
        .toolbar(model.window.covered ? .hidden : .automatic, for: .navigationBar)
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
                model.say("toolbar", "press", ["id": item.id])
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
