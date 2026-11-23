# The agent's browser

`entoli_browser` is the browser the `browser_*` tools drive: `CdpBrowser`,
the core's `AgentBrowser` (`model/agent_browser.dart`), over the Chrome
DevTools Protocol (`cdp.dart`). On the desktops it launches a Chromium-family
executable, or the Helium it downloads (`helium.dart`); on Android it connects
to the app's own WebViews, and on iOS `webkit_connection.dart` stands in for
the protocol over WKWebViews. `entoli_browser.dart` is the entry point; the
app builds it in `createAgentBrowser` (`lib/core/platform/host.dart`) and
`main` hands the same instance to the backend and to `agentBrowserProvider`.
The native halves, `BrowserChannel.kt` and `BrowserChannel.swift`, stay in the
Runners, behind the `agent_chat/browser` method channel.

What the tools offer, how they are gated, signing in and the notes the agent
is told are "The browser" in `packages/entoli_core/lib/agent/AGENTS.md`; the
chat's card is "The agent's browser, on screen" in `lib/ui/chat/AGENTS.md`.

## On the desktops

**Helium is the embedded one for its uBlock Origin**: pages come without the
ads and trackers, and without most of the scripts that would put text in front
of the model. It is fetched from `imputnet/helium-<os>`'s latest release —
the tag read off the `releases/latest` redirect, as the app's own update check
does — into `<cache>/browser/download/`: the AppImage on Linux, which runs
where it is put, the `.app` out of the dmg on macOS, the portable zip on
Windows. Installed whole beside it and renamed over, so a download that dies
leaves the last one working; the running browser is quit first, since Windows
will not replace a file in use.

The browser is launched on the first call that needs it and quit after ten
idle minutes. `--remote-debugging-port=0` lets it pick a port, which it writes
to `DevToolsActivePort` in the profile — nothing is guessed, so nothing can be
taken. Its environment is the one `environment` gives, whole: the app binds
`entoli_shell`'s `environmentWithoutAppImage`, the same a command gets, since
Helium's own AppImage runtime would read ours. A launch that exits 0 at once
is a browser handing off to a copy already open on that profile, and is said
as that. One that exits 21 is a browser already holding the profile's lock,
left by a crash or by an app that did not close it (an AppImage's browser
outlives its parent): the session's dispose closes the browser at exit, and
every launch first quits whatever process the lock names if it was started on
this very profile (`reapLostBrowser`).
Settings > Agent Browser's Quit is `close()`: `Browser.close`
over the protocol, then a kill if it has not gone in five seconds. Its Delete
browser data is `clearData()`: a launch in flight is waited out, the browser
quit, then the profile deleted whole — one profile whichever browser is
picked, so one button signs the agent out of everything. The Helium download
beside it is its own Delete.

**Hidden by default** (`agentBrowserVisible` off, written only when on): the
browser runs `--headless=new`, which is the real browser with no window, and
says so in its user agent — `HeadlessChrome`, the first thing a bot check
reads. So the first hidden launch of an executable each run asks it for its
user agent, quits, and launches again with `--user-agent` set to the same
string with `Chrome` in its place; by flag rather than per tab, so a
cross-site frame and a worker send it too. Every launch, window or none,
passes `--disable-blink-features=AutomationControlled`: remote debugging alone
sets `navigator.webdriver`, the second thing such a check reads. A hidden
browser is shown only when the user asks, from the chat's browser card ("Open
in a window"): it quits and starts again with a window, on the same profile and
page, and is hidden again from its next quit, idle or by hand. The agent has
no tool for it; whether the browser is on screen is the user's choice, and the
card already shows the page.

**One tab per chat**, so two turns at once do not navigate each other; a tab
the user closes is opened again on the next call, and is brought to the front
before each one — Chrome throttles a background tab until a screenshot of it
never arrives. Sub-agents get no tab: a fan-out on one window is workers
fighting over it.

What the model reads after every call is the view: title, URL, scroll
position, the interactive elements in view numbered `[n]`, and the text in
view. The page script (`page_script.dart`) runs in an isolated world, so the
page's own scripts cannot see or replace it. The world is made once per
document and kept: each one made lives until the page navigates, so one per
call would pile up hundreds on a long session in an editor. The numbers
live on the DOM as `data-entoli-ref`, so an element keeps its number for as
long as its document does. Cross-site frames are invisible to it — a separate
process, and a challenge widget's sits in a closed shadow root besides — so
they are read off the browser's target list and named on the view, and a
challenge frame or a page saying it is one adds a note telling the model to
screenshot and click, or to ask the user to solve it in the window.

Input is the protocol's, not the page's: a click is `Input.dispatchMouseEvent`,
which a page sees as trusted, arriving along a short eased path off the exact
centre; a drag moves in uneven steps. That is what lets a click by `x`, `y`
reach a checkbox inside a cross-site frame. Screenshots are taken at a scale of
one over `devicePixelRatio`, so a pixel in the image is a CSS pixel in the
viewport and a point read off one clicks where it was read — on a HiDPI screen
it would otherwise be off by the ratio.

`browser_scroll` is a wheel, and a wheel scrolls the innermost scroller under
it, so where it turns picks the target: the viewport's middle by default, a
`ref`'s centre or an `x`, `y` to scroll a panel or frame of its own. A webmail
body in an iframe is the case: with the wheel always at the middle, each
scroll would move the page around the frame and never the message in it. The view's
scroll position is the page's alone, so a scroll that leaves it where it was
says so, pointing at a screenshot for what did move.

**A passkey request freezes a hidden page.** Google's sign-in asks for one on
load; Chrome answers with a dialog of its own that takes input from the page,
and a headless browser has nowhere to draw it — so the page looks fine and
swallows every click, "Try another way" included. Each tab of a hidden browser
is therefore put under the protocol's virtual authenticators with their UI off
(`WebAuthn.enable`, `enableUI: false`): the request waits silently with no
authenticator to answer it, and the page stays clickable. A windowed browser
keeps the real dialog, which is how a passkey is actually used, so the card's
"Open in a window" (`show()`, noted to the agent since the restart reloads
the page) is the way to sign in with one.

## On Android

There is no browser to launch, so the browser is the app's own WebView (the
same Chromium), one per chat, made by `BrowserChannel.kt`. With debugging on,
WebView serves the protocol on the abstract socket
`@webview_devtools_remote_<pid>`, which Chromium lets the app's own user
connect to. `CdpBrowser` with `webViews` set connects there rather than
launching, and the rest of the tab code is unchanged, trusted
`Input.dispatchMouseEvent` clicks included. Debugging is on only while the
browser runs, since adb's shell can reach the socket too. The protocol cannot
create a WebView (`Target.createTarget` fails), so the channel makes one on
`about:blank?entoli=<chat>` and the tab finds its target by that address.

**The WebViews live on a private `VirtualDisplay`**, in a `Presentation`
whose frames go into an `ImageReader` that throws them away. A WebView whose
window is not visible stops answering clicks as well as screenshots, and the
activity's window is not visible while a turn runs with the app in the
background or the screen off. The display is the app's own and needs no
permission. All of this was checked on an emulator: clicks, screenshots and
the screencast with the app backgrounded and with the screen off.

`AgentBrowser.inApp` is what the UI reads, not the platform: Settings > Agent
Browser is then a switch, **on by default**: unset and `webViewBrowserId` are
on, `browserOffId` is what turning it off writes, and any other value, a
desktop's path from a restored backup, is off. Off has to be written because
unset is on — the desktops' the other way round, where Helium's setup step
is what turns theirs on. There is no window toggle and no Helium, and the
chat's browser card, the user's view of the page,
draws no "Open in a window". What it lacks: downloads (a WebView's go to a
`DownloadListener`, not the protocol) and uBlock Origin. Passkeys are
rejected rather than missing: WebView has no WebAuthn unless the app opts in,
so `PublicKeyCredential` is undefined and `navigator.credentials.get` and
`create` fail at once with `NotSupportedError`, and a sign-in page falls back
to its other ways (checked on an emulator). It also identifies itself as a
WebView (`; wv` in the user agent, `X-Requested-With`), so it meets more human
checks than Helium does.

## On iOS

The browser is a WKWebView per chat, made by `BrowserChannel.swift`, and the
settings are Android's switch, less the upload policy, which
`AgentBrowser.trustedInput` hides since there are no uploads to govern. WebKit
serves no protocol an app can reach, so `WebKitConnection` answers the slice of
it the tab sends — the tab is the same code — in terms of the channel: a script
is `evaluateJavaScript` (the isolated world a named `WKContentWorld`; nothing
the tab runs returns a promise, so the completion value is the answer), a
screenshot or a screencast frame is `takeSnapshot` at one pixel per CSS pixel,
the screencast a few snapshots a second, each waiting on the last one's ack.
Cross-site frames are the subframe navigations the delegate saw, since a
challenge's sits in a closed shadow root. Anything else the tab could send says
it is not on iOS.

**Input is the page's own events**, made in the isolated world: a click is
pointer and mouse events and a `click` at the element under the point, a key
a `KeyboardEvent` with what it would have done done after (`execCommand`), a
wheel a `scrollBy` on the innermost scroller. iOS has no public way to inject
a touch, so a page sees every one as untrusted and none reaches into a
cross-site frame. `BrowserTab.trustedInput` is false, and that is what says
so: it reaches the turn as `ToolOffer.trustedInput`, where `browser_drag` and
`browser_upload` read it and are not offered, and a human check's
note sends it to the user through `browser_credentials_hide` rather than
suggesting a click. The card's "Open in a window" is `show()`, the real view
presented full screen, where the user's touches are real.

The views sit in a window of their own under the app's, visible so WebKit
keeps drawing and running them, and never key. A script counts as a gesture
to WebKit, so a focus the page script makes is a real one: in the app's own
window it brought the keyboard up over the app and zoomed the page into the
field. Each script is therefore followed by `endEditing` while the page is
not shown — the page keeps its focus, so typing still lands. A page with no
viewport tag is drawn at its 980 CSS pixels zoomed out, so a snapshot's rect
is scaled by the view's zoom. All of this was found and checked on the
simulator: typing, clicks, links, back, the screencast, screenshots of both
kinds of page, and `show()` and its Done. The app is suspended in the
background, so the browser works only while it is open, and a call made
otherwise says so. What it lacks beyond Android's: drag, uploads and downloads
(a download is a navigation WebKit cancels), and the user's card input is as
untrusted as the agent's.

## The file chooser

A page's file chooser is a native dialog, which neither the agent nor a
hidden browser can use, so it is caught instead: `_openChooser` turns on
`Page.setInterceptFileChooserDialog`, clicks the element the agent named —
the field itself, or a button that opens a hidden one, the common pattern —
and takes the `Page.fileChooserOpened` the click raises, with the protocol's
id for the field and whether it takes several files. `DOM.setFileInputFiles`
fills it; the page sees an ordinary `change` with the files in it.

## Downloads

A download lands in the chat's workspace, `downloads/` under it, which is
`BrowserTab.downloadDir`, set by the turn that hands the tab over. The
protocol's download behaviour is the browser's rather than a tab's, so one
directory per chat cannot be set on it: `Browser.setDownloadBehavior` with
`allowAndName` sends every download into `<cache>/browser/downloads/` under
the browser's id for it, and `_deliver` moves the finished file into the tab
it came from under its own name, ` (1)` added where one is there already. The
tab is found by `Browser.downloadWillBegin`'s frame: a tab's main frame has
the tab's id, a popup names its opener, and a frame inside a page is looked
up in each tab's frame tree. The agent hears of each one as a note on its
next browser result. A hidden browser refuses every download without this,
which is why it is set at every start. What could not be matched to a tab is
left in staging, logged, and cleared at the next start.
