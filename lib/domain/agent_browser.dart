import "dart:typed_data";

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

  /// The viewport, or the element [ref] alone, as a PNG at CSS-pixel scale.
  Future<BrowserShot> screenshot({int? ref});

  /// What a click on [ref], or at ([x], [y]), would act on and where — the
  /// words an approval is asked in, since a number means nothing to a person.
  Future<String> describeTarget({int? ref, double? x, double? y});
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
