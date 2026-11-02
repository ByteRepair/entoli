import SwiftUI

/// The window: a split view whose sidebar is native and whose detail is the
/// Flutter view, the shell's chrome over it. The Flutter view fills the
/// detail, under the toolbar and whatever the shell puts at the bottom; how
/// far those reach is the safe area, which goes to Dart as padding.
struct ShellView: View {
  @ObservedObject var model: ShellModel
  let flutter: PlatformViewController

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
          // Under the toolbar and the bottom bar, which it scrolls beneath;
          // never under the sidebar, which on 26 floats over the detail.
          .ignoresSafeArea(edges: [.top, .bottom])
          .onChange(of: proxy.safeAreaInsets, initial: true) { _, insets in
            model.insets(EdgeInsets(top: insets.top, leading: 0, bottom: insets.bottom, trailing: 0))
          }
      }
      .navigationTitle("Entoli")
    }
    .preferredColorScheme(model.window.colorScheme)
  }
}
