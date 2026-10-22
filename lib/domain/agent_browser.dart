import "dart:typed_data";

import "package:flutter/foundation.dart" show ValueListenable, ValueNotifier;

import "download.dart";

/// The browser the agent drives: a real one, with a window the user can see
/// and a profile that keeps its logins, reached over the Chrome DevTools
/// Protocol on the desktops. See "The browser" in `lib/data/builtin/AGENTS.md`.
///
/// One instance per app, shared by the backend that drives it and the
/// settings page that picks it — the page has to close the running browser
/// before the embedded one can be replaced under it.
abstract class AgentBrowser {
  const AgentBrowser();

  /// Whether this platform can drive a browser at all. False on the phones
  /// and the web; the settings category is not drawn there.
  bool get available;

  /// Whether a browser is picked and there to launch: what offers the tools.
  /// Asked per turn, so a pick reaches the next turn without a restart.
  bool get configured;

  /// Whether it runs with no window: the setting's default. A hidden browser
  /// can still be shown for the user to finish a check, until it next quits.
  bool get hidden;

  /// Whether a browser process is up, for the settings page's Quit.
  ValueListenable<bool> get running;

  /// The tab [chatId] drives, opened on first use. One tab per chat, so two
  /// chats running at once do not navigate each other's page.
  BrowserTab tab(String chatId);

  /// The Chromium-family browsers found on this machine.
  Future<List<FoundBrowser>> detect();

  /// The executable [picked] names — a `.app` on macOS resolves to the binary
  /// inside it — once it has been launched and answered over the DevTools
  /// Protocol. Throws, with what went wrong, where it does not.
  Future<String> verify(String picked);

  /// The browser the app downloads itself: Helium, for the uBlock Origin it
  /// ships with.
  EmbeddedBrowser get embedded;

  /// Quit the browser, if one is running. The next call starts it again.
  Future<void> close();
}

/// A browser found installed, by the name a user knows it under.
class FoundBrowser {
  const FoundBrowser(this.name, this.path);

  final String name;
  final String path;
}

/// The downloaded browser: what is installed, and fetching or removing it.
abstract class EmbeddedBrowser {
  /// The version on disk, or null when none is.
  String? get installedVersion;

  /// The executable to launch, or null when none is installed.
  String? get executable;

  /// The newest release's version.
  Future<String> latestVersion();

  /// Download the newest release in place of whatever is installed.
  Stream<DownloadProgress> install();

  Future<void> remove();
}

/// One chat's page. Every call but [screenshot] answers with text for the
/// model, describing the page as the call left it; a failure throws.
abstract class BrowserTab {
  /// The page while the browser has this tab open, null otherwise: what the
  /// chat's browser chip is drawn from.
  ValueListenable<BrowserPage?> get page;

  /// What the tab draws, frame by frame, for as long as it is listened to —
  /// hidden or not. Ends when the tab closes; empty where it is not open.
  Stream<BrowserFrame> frames();

  // The user's own hands on the page, from the chat's browser card. They act
  // only on a tab that is open — none starts a browser — and they are not
  // gated: the user is the one doing it.

  Future<void> forward();

  Future<void> reload();

  /// A mouse event at a viewport point, in CSS pixels.
  Future<void> pointer(BrowserPointer event);

  Future<void> key(BrowserKey event);

  /// Text typed at the caret, as a paste puts it there.
  Future<void> insertText(String text);

  Future<String> goto(String url);

  Future<String> back();

  /// Click the element numbered [ref] by an earlier description, or the
  /// viewport point ([x], [y]) in CSS pixels — what a screenshot shows.
  Future<String> click({int? ref, double? x, double? y});

  /// Press at [from] and release at [to], moving between: a slider.
  Future<String> drag(
      ({double x, double y}) from, ({double x, double y}) to);

  /// Replace the text in [ref] with [text], and press Enter after if [submit].
  Future<String> type(int ref, String text, {bool submit = false});

  /// One viewport down, or up.
  Future<String> scroll({bool up = false});

  /// The whole page's text and elements, from character [offset] on.
  Future<String> pageText({int offset = 0});

  /// Bring the browser up with a window on this page, for the user to finish
  /// what the agent cannot. It goes back to hidden the next time it quits.
  Future<String> show();

  /// The viewport, or the element [ref] alone, as a PNG at CSS-pixel scale.
  Future<BrowserShot> screenshot({int? ref});

  /// What a click on [ref], or at ([x], [y]), would act on and where — the
  /// words an approval is asked in, since a number means nothing to a person.
  Future<String> describeTarget({int? ref, double? x, double? y});
}

/// An open tab's page. [opened] counts the tab being opened, so a view of its
/// frames knows to listen again after the tab was closed and reopened.
class BrowserPage {
  const BrowserPage({required this.url, this.title = "", required this.opened});

  final String url;
  final String title;
  final int opened;

  BrowserPage copyWith({String? url, String? title}) =>
      BrowserPage(url: url ?? this.url, title: title ?? this.title, opened: opened);
}

/// One frame of a tab's screencast: a JPEG, and the viewport size it shows.
class BrowserFrame {
  const BrowserFrame(this.jpeg, {required this.width, required this.height});

  final Uint8List jpeg;
  final double width;
  final double height;
}

enum BrowserPointerKind { move, down, up, wheel }

/// A mouse event as the DevTools Protocol takes one. [button] is `left`,
/// `middle`, `right` or `none`; [buttons] the held ones as a bitmask (1 left,
/// 2 right, 4 middle); [modifiers] the held keys (1 Alt, 2 Ctrl, 4 Meta,
/// 8 Shift).
class BrowserPointer {
  const BrowserPointer(
    this.kind, {
    required this.x,
    required this.y,
    this.button = "none",
    this.buttons = 0,
    this.clickCount = 0,
    this.deltaX = 0,
    this.deltaY = 0,
    this.modifiers = 0,
  });

  final BrowserPointerKind kind;
  final double x;
  final double y;
  final String button;
  final int buttons;
  final int clickCount;
  final double deltaX;
  final double deltaY;
  final int modifiers;
}

/// A key going down or up, named as the DOM names it: [key] is the value
/// (`a`, `Enter`), [code] the physical key (`KeyA`, `Enter`), [keyCode] the
/// legacy number pages still read. [text] is what a press inserts, null for a
/// key that inserts nothing. [commands] are the editing commands a shortcut
/// stands for (`selectAll`, `copy`), which a synthesized key does not run on
/// its own.
class BrowserKey {
  const BrowserKey({
    required this.down,
    required this.key,
    required this.code,
    required this.keyCode,
    this.text,
    this.modifiers = 0,
    this.commands = const [],
  });

  final bool down;
  final String key;
  final String code;
  final int keyCode;
  final String? text;
  final int modifiers;
  final List<String> commands;
}

/// A screenshot and where its top-left corner is in the viewport, so a point
/// read off a cropped one can be clicked.
class BrowserShot {
  const BrowserShot(this.png, {this.left = 0, this.top = 0});

  final Uint8List png;
  final double left;
  final double top;
}

/// The setting's value for the downloaded browser; anything else non-null is
/// an executable's path.
const embeddedBrowserId = "embedded";

/// Where there is no browser to drive: the phones and the web.
class UnavailableAgentBrowser extends AgentBrowser {
  const UnavailableAgentBrowser();

  @override
  bool get available => false;

  @override
  bool get configured => false;

  @override
  bool get hidden => true;

  static final _notRunning = ValueNotifier(false);

  @override
  ValueListenable<bool> get running => _notRunning;

  @override
  BrowserTab tab(String chatId) =>
      throw UnsupportedError("There is no browser on this platform.");

  @override
  Future<List<FoundBrowser>> detect() async => const [];

  @override
  Future<String> verify(String picked) =>
      throw UnsupportedError("There is no browser on this platform.");

  @override
  EmbeddedBrowser get embedded =>
      throw UnsupportedError("There is no browser on this platform.");

  @override
  Future<void> close() async {}
}
