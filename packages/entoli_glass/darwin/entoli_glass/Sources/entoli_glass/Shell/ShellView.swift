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
      List {}
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    } detail: {
      GeometryReader { proxy in
        FlutterPane(controller: flutter)
          .ignoresSafeArea()
          .onChange(of: proxy.safeAreaInsets, initial: true) { _, insets in
            model.insets(insets)
          }
      }
      .navigationTitle("Entoli")
    }
    .preferredColorScheme(model.window.colorScheme)
  }
}
