# Opening links and receiving incoming ones

`entoli_links` is the adapter for a URL crossing the app's edge, either way.
`entoli_links.dart` is the whole of it, bound in `main`:

- `PluginLinkLauncher` answers the core's `LinkLauncher` with `url_launcher`:
  `openExternal` hands a URL to the app its scheme belongs to, and
  `openInAppBrowser` to the system's in-app browser (SFSafariViewController,
  a Custom Tab). It vets nothing. Which schemes reach it, and which route a
  link takes on which platform, is the app's `PlatformLinkOpener` (see
  "Opening a link" in `lib/ui/AGENTS.md`); a page that sends the user to
  another app's screen, like iOS's Settings page for the camera, reads it
  through `linkLauncherProvider`.
- `InAppSignInPages` answers `SignInPages`: it closes the in-app browser a
  CLI's sign-in page was opened in once the program has exited. An
  SFSafariViewController closes; a Custom Tab, which nothing outside it may
  close, stays. `main` binds it on the phones alone, where sign-in opens in
  that browser.
- `incomingLinks` is `app_links`' one stream of the links that open the app,
  the one that launched it and every one after. `main` binds it as
  `appLinksProvider`, which `IncomingLinks` reads; what a link means is the
  core's `AppLink.parse`. How each platform registers the scheme and hands a
  link over is the app's native code — see "Links into Entoli" in
  `lib/ui/AGENTS.md`.

The share viewer has links of its own to open and imports `url_launcher`
directly, as `entoli_files`' hand-offs do: a web page and a file have their
own routes out.
