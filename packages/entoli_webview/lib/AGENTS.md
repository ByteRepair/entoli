# The in-app web view

`entoli_webview` is the adapter for the platform's web view, the one a link
opens in on Android and an artifact opens in on the phones.
`entoli_webview.dart` is the whole of it: `PluginWebView` answers the core's
`WebView` (`view/web_view.dart`) with `webview_flutter`, and `main` hands it
to `PlatformLinkOpener` beside the launcher. The view is the plugin, so the
widget lives here and the opener's pages (`lib/ui/link_opener.dart`, see
"Opening a link" in `lib/ui/AGENTS.md`) ask for it, handing it a URL and what
to do with each place the page lands.

Scripts are on. Back goes through the page's own history before it leaves
the route, which is a `PopScope` the view owns. The view says where it is on
each finished load and on each address change without a load, with the
page's title, so the link page's Copy link and Open in browser act on the
page navigated to and the artifact page takes the page's own `<title>`.

An artifact is a loopback `http://` URL the app serves from the artifact's
directory (`lib/core/platform/artifact_server.dart`), since Android's
WebView refuses `file://`; to this view it is a URL like any other.

`webview_flutter_android` is here for one setting the platform-neutral API
cannot ask for: hybrid composition. The plugin's Android default draws into
a texture Flutter composites, which lags scrolling by a frame; hybrid
composition puts the native view on screen to scroll by itself.

The agent's browser is not this: it is the app's own native channel
(`BrowserChannel.kt` and `.swift`), driven over the DevTools Protocol. See
"The browser (the `browser_*` tools)" in
`packages/entoli_core/lib/agent/AGENTS.md`.

The test fakes `webview_flutter` at its platform interface
(`webview_flutter_platform_interface`, a dev dependency): the plugin has no
implementation on a test host, and `WebViewController()` throws without one.
