import SwiftUI

/// The window: a split view whose sidebar is native and whose detail is the
/// conversation, drawn natively, over the Flutter view that keeps the pages
/// pushed over it, the shell's chrome over both. The Flutter view fills the
/// detail, under the toolbar and the composer; how far those reach is the
/// safe area, which goes to Dart as padding.
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
    model.ready && collapsed && !model.window.covered && !model.voice.present
      ? model.showSidebar : nil
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
        .toolbar(model.voice.present ? .hidden : .automatic, for: .windowToolbar)
      #endif
      .preferredColorScheme(model.window.colorScheme)
      #if os(macOS)
        // The app's, not the window's: popovers, menus and sheets are windows
        // of their own, and the system's glass follows the app. Nil follows the
        // system.
        .onChange(of: model.window.dark, initial: true) { _, dark in
          NSApp.appearance = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
        }
        .reportsPointer(over: flutter, to: model)
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

  /// The conversation is native and on screen: a chat is open, and no
  /// Flutter page, dialog or new-chat screen is over it.
  private var conversing: Bool {
    model.ready && transcript.present && !model.window.overlaid && !model.newChat.present
  }

  /// Nothing on screen needs the Flutter view: a chat or the new-chat screen
  /// is up, both published from the app's state, and no Flutter page or
  /// dialog is over them.
  private var flutterAway: Bool {
    model.ready && !model.window.overlaid && (transcript.present || model.newChat.present)
  }

  private var detail: some View {
    ZStack {
      // Out of the window while a chat or the new-chat screen is up: both are
      // published from the app's state, which needs no frame (`ShellChat`).
      // In it for a Flutter page or dialog over them, and the app before it
      // is set up.
      Group {
        if flutterAway {
          // Holds the place, so the insets below are still measured.
          Color.clear
        } else {
          FlutterCanvas(flutter: flutter) {
            StripLayer(model: model)
          }
        }
      }
      .onGeometryChange(for: EdgeInsets.self) { proxy in
        EdgeInsets(
          top: proxy.safeAreaInsets.top, leading: 0, bottom: proxy.safeAreaInsets.bottom,
          trailing: 0)
      } action: { model.insets($0) }
      #if os(iOS)
        // The Flutter view keeps the whole height and shrinks its page for
        // the keyboard itself; the inset still reaches over the keyboard,
        // which Dart's `ShellInsets` takes out.
        .ignoresSafeArea(.keyboard)
      #endif
      if conversing {
        GeometryReader { proxy in
          ConversationView(
            model: transcript,
            bottom: max(
              0,
              proxy.safeAreaInsets.bottom
                - ComposerView.menuLift(rows: model.composer.menu.count))
          )
          .ignoresSafeArea(.container, edges: .bottom)
        }
        .safeAreaInset(edge: .top, spacing: 0) { DeviceBanner(foot: model.foot) }
        .background(.background)
        .transition(.opacity)
      }
      // Beside the Flutter view rather than over it, so it keeps to the
      // keyboard's safe area: the composer rides on the keyboard and pads
      // the new-chat screen up with it, where an overlay of the view above
      // would have run on under the composer and the keys.
      if model.newChat.present && !model.window.covered {
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
        if !model.turn.isEmpty && !model.window.covered {
          TurnSurfaceView(model: model)
            .padding(.top, 6)
            .frame(maxWidth: ShellView.readableWidth + 16)
            .frame(maxWidth: .infinity)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        ComposerSlot(composer: model.composer, covered: model.window.covered)
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
/// it. Its own view, so only it reads the composer.
private struct ComposerSlot: View {
  var composer: ComposerModel
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
  /// The chat's leads with [toList] where there is one.
  fileprivate func windowBar(_ model: ShellModel, toList: (() -> Void)?) -> some View {
    let page = model.window.covered
    let bar =
      !page
      ? model.chatBar.titleBar
      : model.pageBar.present ? model.pageBar : model.chatBar.titleBar.bare
    return self
      .titleBar(
        bar, intents: page ? model.say.pageBar as TitleBarIntentsProtocol : model.say.chatBar,
        sidebar: toList)
      #if os(iOS)
        // A page whose bar Flutter still draws has it alone: one on screen.
        .toolbar(page && !model.pageBar.present ? .hidden : .automatic, for: .navigationBar)
      #endif
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

#if os(macOS)
  extension View {
    /// The pointer over the window, in [flutter]'s own coordinates, for the
    /// agent's face to follow wherever it is over the window: the sidebar
    /// lies to the view's left, so its x is negative there, and AppKit's
    /// bottom-left origin is flipped to Flutter's top-left.
    fileprivate func reportsPointer(over flutter: NSViewController, to model: ShellModel)
      -> some View
    {
      onContinuousHover { _ in
        guard let window = flutter.view.window else { return }
        let view = flutter.view
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        model.say.window.pointer(x: point.x - view.bounds.minX, y: view.bounds.maxY - point.y) { _ in }
      }
    }
  }
#endif
