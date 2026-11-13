import SwiftUI

/// The window: a split view whose sidebar is native and whose detail is the
/// conversation or the new-chat screen, the composer and the turn surface
/// under them, every page of the app's in a sheet over it, all drawn from
/// what the core sends. Nothing of Flutter's is drawn: its view is in the
/// window only as the engine's host (`EngineHost`).
struct ShellView: View {
  @Bindable var model: ShellModel
  let flutter: PlatformViewController

  /// The conversation, drawn here from the core's transcript rather than by
  /// the Flutter view beneath it.
  private let transcript = TranscriptModel.shared!

  /// The conversation's column in the Flutter view, which the composer is
  /// held to as the Flutter one is: `_readableWidth`, and the composer's own
  /// padding either side.
  static let readableWidth: CGFloat = 760

  /// The split view's own, so a change of it is animated whichever end made
  /// it: the system's button animates on its own, and a change Dart made — the
  /// View menu, its key — is put in an animation below. Dart is told of the
  /// first and is the source of the second.
  @State private var columns = NavigationSplitViewVisibility.all

  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var width
    /// An iPhone's split view: one column at a time, the list a screen of
    /// its own to get back to.
    private var collapsed: Bool { width == .compact }
  #else
    private let collapsed = false
  #endif

  /// The way to the list on an iPhone, the chat in front: the bar's sidebar
  /// button, and the drawer's swipe in from the edge. A Flutter page keeps
  /// the edge for its own back swipe.
  private var toList: (() -> Void)? {
    model.ready && collapsed && !model.voice.present
      ? model.showSidebar : nil
  }

  /// The first launch's card over the window, which hides the toolbar as
  /// voice mode does.
  private var cardUp: Bool {
    guard let pages = AppPagesModel.shared else { return false }
    return pages.held && !pages.stack.isEmpty
  }

  /// The browser's view, closed from the sheet's own dismissal too.
  private var browserShown: Binding<Bool> {
    Binding(
      get: { model.browser.present },
      set: { if !$0 && model.browser.present { model.say.browser.close { _ in } } })
  }

  /// Before the app is up — the welcome tour, first-run setup — the
  /// conversation's column alone, whatever the split view is asked.
  private var shownColumns: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: { model.ready ? columns : .detailOnly },
      set: { if model.ready { columns = $0 } })
  }

  var body: some View {
    layout
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
      .sheet(isPresented: browserShown) { BrowserSheet(model: model) }
      // The app's pages: a chat's settings, the plan, the workspace.
      .modifier(AppPagesPresenter())
      .modifier(DialogPresenter(model: model))
      #if os(iOS)
        .sheet(
          isPresented: Binding(
            get: { model.scanning }, set: { if !$0 { model.scanned(nil) } })
        ) { CodeScanner(model: model) }
      #endif
      // A line said in passing, over everything but voice mode.
      .overlay(alignment: .top) {
        if !model.voice.present { NoticeView(model: model) }
      }
      // Voice mode is the whole window: nothing of the toolbar's — the title,
      // the new chat and sidebar buttons — stands over it.
      #if os(macOS)
        .toolbar(model.voice.present || cardUp ? .hidden : .automatic, for: .windowToolbar)
      #endif
      .preferredColorScheme(model.window.colorScheme)
      #if os(macOS)
        // The app's, not the window's: popovers, menus and sheets are windows
        // of their own, and the system's glass follows the app. Nil follows the
        // system.
        .onChange(of: model.window.dark, initial: true) { _, dark in
          NSApp.appearance = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
        }
      #endif
      // `columns` is the user's choice alone; `shownColumns` hides it before
      // the app is up. Gating it here too wrote the hidden column back to Dart
      // at launch, and the sidebar started collapsed.
      .onChange(of: model.window.sidebarShown, initial: true) { _, shown in
        let wanted: NavigationSplitViewVisibility = shown ? .all : .detailOnly
        guard wanted != columns else { return }
        withAnimation(.smooth(duration: 0.3)) { columns = wanted }
      }
      .onChange(of: columns) { _, columns in
        let shown = columns != .detailOnly
        if shown != model.window.sidebarShown { model.say.window.sidebarShown(shown: shown) { _ in } }
      }
  }

  /// The split view; on an iPhone, the drawer, which a swipe moves under the
  /// finger where the split view's one column could only jump.
  @ViewBuilder private var layout: some View {
    #if os(iOS)
      if collapsed {
        Drawer(
          column: model.ready ? $model.compactColumn : .constant(.detail), opens: toList != nil
        ) {
          if model.ready { NavigationStack { SidebarView(model: model, collapsed: true) } }
        } detail: {
          NavigationStack { detail }
        }
      } else {
        split
      }
    #else
      split
    #endif
  }

  private var split: some View {
    NavigationSplitView(columnVisibility: shownColumns) {
      // Nothing to swipe in before the app is up.
      if model.ready {
        SidebarView(model: model, collapsed: false)
          .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
      }
    } detail: {
      detail
    }
    .toolbar(removing: model.ready ? nil : .sidebarToggle)
  }

  /// A chat is open, and the new-chat screen is not over it.
  private var conversing: Bool {
    model.ready && transcript.present && !model.newChat.present
  }

  private var detail: some View {
    ZStack {
      Color.clear
        // The engine's view, held in the window and drawing nothing.
        .background { EngineHost(flutter: flutter) }
      if conversing {
        GeometryReader { proxy in
          ConversationView(
            model: transcript,
            bottom: max(
              0,
              proxy.safeAreaInsets.bottom
                - ComposerView.menuLift(rows: model.composer.menu.count))
          )
          // Under the keyboard too: [bottom] already counts it, and a frame
          // ending at the keyboard counted it twice.
          .ignoresSafeArea(edges: .bottom)
        }
        .safeAreaInset(edge: .top, spacing: 0) { DeviceBanner(foot: model.foot) }
        .background(.background)
        .transition(.opacity)
      }
      // In the keyboard's safe area: the composer rides on the keyboard and
      // pads the new-chat screen up with it.
      if model.newChat.present {
        NewChatView(model: model).transition(.opacity)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        if conversing {
          BrowserPromptsView(foot: model.foot, say: model.say.foot)
            .frame(maxWidth: ShellView.readableWidth + 16)
            .frame(maxWidth: .infinity)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        if !model.turn.isEmpty {
          TurnSurfaceView(model: model)
            .padding(.top, 6)
            .frame(maxWidth: ShellView.readableWidth + 16)
            .frame(maxWidth: .infinity)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        ComposerSlot(composer: model.composer)
        if conversing && !model.composer.present {
          FootBarView(foot: model.foot, say: model.say.foot)
            .frame(maxWidth: ShellView.readableWidth + 16)
            .frame(maxWidth: .infinity)
        }
      }
      .animation(ComposerView.motion, value: model.turn.isEmpty)
      .animation(ComposerView.motion, value: model.foot)
    }
    .windowBar(model, toList: toList)
    .welcome(!model.ready)
  }
}

/// The engine's view, which the app needs in the window for the engine's
/// lifecycle and for the plugins that present from it — a file chooser, a
/// share sheet — and which draws nothing the user sees: a point of it,
/// clear, taking no input, and hidden from accessibility.
private struct EngineHost: View {
  let flutter: PlatformViewController

  var body: some View {
    FlutterPane(controller: flutter)
      .frame(width: 1, height: 1)
      .opacity(0)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

/// The composer, where the page in front has one. Its own view, so only it
/// reads the composer.
private struct ComposerSlot: View {
  var composer: ComposerModel

  var body: some View {
    if composer.present {
      ComposerView(model: composer)
        .frame(maxWidth: ShellView.readableWidth + 16)
        .frame(maxWidth: .infinity)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }
}

extension View {
  /// The window's title bar: the chat's, leading with [toList] where there
  /// is one.
  fileprivate func windowBar(_ model: ShellModel, toList: (() -> Void)?) -> some View {
    titleBar(model.chatBar.titleBar, intents: model.say.chatBar, sidebar: toList)
  }
}

extension View {
  /// The welcome tour and first-run setup stand alone, with no bar to
  /// leave by: set on the column, whose bar it is.
  fileprivate func welcome(_ on: Bool) -> some View {
    #if os(macOS)
      toolbar(on ? .hidden : .automatic, for: .windowToolbar)
    #else
      toolbar(on ? .hidden : .automatic, for: .navigationBar)
    #endif
  }
}


