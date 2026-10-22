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
  /// [why] is the note each open tab's agent is left.
  Future<void> close({String why = "The user quit the browser."});
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

  /// What happened in the browser that the agent did not do — the user's
  /// navigation, hiding, quitting — in order, since it was last asked. The
  /// agent puts them on its next browser result, where the log keeps them;
  /// a turn is never handed a message mid-flight.
  List<String> takeNotes();

  // The user's own hands on the page, from the chat's browser card. They act
  // only on a tab that is open — none starts a browser — and they are not
  // gated: the user is the one doing it. Each leaves a note for the agent.

  /// The user's back, where [back] is the agent's: the same move, but this
  /// one is noted.
  Future<void> historyBack();

  Future<void> forward();

  Future<void> reload();

  /// A mouse event at a viewport point, in CSS pixels.
  Future<void> pointer(BrowserPointer event);

  Future<void> key(BrowserKey event);

  /// Text typed at the caret, as a paste puts it there.
  Future<void> insertText(String text);

  // Private input: what the user types for a sign-in reaches the page from
  // here, never through the agent, the backend or the log.

  /// Non-null while the browser is hidden from the agent, by the user or by
  /// the agent asking for it. Every agent tool refuses while it is set; the
  /// user's own input from the card still works.
  ValueListenable<BrowserHold?> get hold;

  void hide(BrowserHold hold);

  void unhide();

  /// The sign-in the agent is waiting on, for the chat to draw a panel for.
  ValueListenable<CredentialRequest?> get credentialRequest;

  /// The agent's side: wait for the user to fill [request] in. Answers with
  /// the page as the submit left it — never the values. Throws
  /// [CredentialsDeclined] where the user declines or [cancelCredentials]
  /// runs.
  Future<String> requestCredentials(CredentialRequest request);

  /// The user's side: type [values], one per field, into the page, then run
  /// the submit clicks. Nothing else sees the values.
  Future<void> submitCredentials(List<String> values);

  void declineCredentials();

  /// The turn waiting on it stopped: the panel goes, and the wait ends.
  void cancelCredentials();

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
  /// what the agent cannot — a passkey is one, its dialog having nowhere to
  /// draw in a hidden browser. It goes back to hidden the next time it quits.
  /// Nothing where it has a window already. [byUser] notes it to the agent:
  /// the restart reloads the page.
  Future<String> show({bool byUser = false});

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

/// The browser hidden from the agent. [reason] is the agent's words for the
/// chat's button, where the agent asked; null where the user hid it.
class BrowserHold {
  const BrowserHold({this.reason});

  final String? reason;

  bool get byAgent => reason != null;
}

/// One field of a sign-in: an element numbered by an earlier page
/// description, and what the user is asked for. [secret] obscures what they
/// type.
class CredentialField {
  const CredentialField({required this.ref, required this.label, this.secret = false});

  final int ref;
  final String label;
  final bool secret;
}

/// What the agent asks the user to fill in, and the clicks that submit it.
class CredentialRequest {
  const CredentialRequest({
    required this.reason,
    required this.fields,
    this.submit = const [],
  });

  final String reason;
  final List<CredentialField> fields;
  final List<({int? ref, double? x, double? y})> submit;
}

class CredentialsDeclined implements Exception {
  const CredentialsDeclined(this.message);

  final String message;

  @override
  String toString() => message;
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
  Future<void> close({String why = ""}) async {}
}
