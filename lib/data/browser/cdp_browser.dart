import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:math";

import "package:flutter/foundation.dart" show ValueListenable, ValueNotifier;
import "package:path/path.dart" as p;

import "../../core/log.dart";
import "../../domain/agent_browser.dart";
import "../builtin/local_shell.dart" show environmentWithoutAppImage;
import "cdp.dart";
import "helium.dart";
import "page_script.dart";

const _tag = "browser";

/// A Chromium-family browser launched with its own profile and driven over the
/// DevTools Protocol. Started on the first call that needs it and quit after
/// [idle] with nothing asked of it; the profile stays, so a login outlives
/// the process.
class CdpBrowser extends AgentBrowser {
  CdpBrowser({
    required this.browserDir,
    required this.picked,
    required this.embedded,
    required this.visible,
    this.idle = const Duration(minutes: 10),
  });

  /// `<cache>/browser`: the download, the profile and the probes under it.
  final String browserDir;

  /// The setting: null off, [embeddedBrowserId], or an executable's path.
  final String? Function() picked;

  @override
  final EmbeddedBrowser embedded;

  /// The setting: whether the browser runs with a window.
  final bool Function() visible;

  final Duration idle;

  String get _profile => p.join(browserDir, "profile");

  String? get _executable {
    final value = picked();
    if (value == null) return null;
    if (value == embeddedBrowserId) return embedded.executable;
    return File(value).existsSync() ? value : null;
  }

  @override
  bool get available => true;

  @override
  bool get configured => _executable != null;

  @override
  bool get hidden => !visible();

  final _isRunning = ValueNotifier(false);

  @override
  ValueListenable<bool> get running => _isRunning;

  final _openTabs = ValueNotifier(const <String>{});

  @override
  ValueListenable<Set<String>> get openTabs => _openTabs;

  void _tabsChanged() => _openTabs.value = {
        for (final entry in _tabs.entries)
          if (entry.value._shown.value != null) entry.key,
      };

  _Running? _running;
  Future<_Running>? _starting;
  Timer? _idleTimer;
  final _tabs = <String, _CdpTab>{};

  /// A hidden browser shown for the user by [_CdpTab.show], until it quits.
  bool _shown = false;

  /// Each executable's own user agent with "Headless" taken out, learned on
  /// its first hidden launch this run.
  final _userAgents = <String, String>{};

  @override
  BrowserTab tab(String chatId) =>
      _tabs.putIfAbsent(chatId, () => _CdpTab(this, chatId));

  final _sinceUse = Stopwatch();

  /// Put off the idle quit: the agent or the user is using it. Called per
  /// mouse move, so it restarts a stopwatch rather than a timer.
  void _touch() {
    _sinceUse
      ..reset()
      ..start();
    _idleTimer ??= Timer(idle, _idleCheck);
  }

  void _idleCheck() {
    final left = idle - _sinceUse.elapsed;
    if (left > Duration.zero) {
      _idleTimer = Timer(left, _idleCheck);
      return;
    }
    _idleTimer = null;
    unawaited(
        close(why: "The browser quit after ${idle.inMinutes} idle minutes."));
  }

  /// The running browser, launched if none is or the pick has changed since.
  Future<_Running> _ensure() async {
    _touch();
    final exe = _executable ??
        (throw const CdpException(
            "No browser is picked, or the picked one is gone: see Settings > "
            "Agent Browser."));
    final windowed = _shown || visible();
    final running = _running;
    if (running != null &&
        running.executable == exe &&
        running.windowed == windowed &&
        !running.cdp.isClosed) {
      return running;
    }
    if (running != null) {
      await _quit("The browser restarted: its settings changed.");
    }
    return _starting ??= _start(exe, windowed: windowed).then((started) async {
      await _watchDownloads(started);
      _running = started;
      _isRunning.value = true;
      // The user closed its window, or it crashed: a quit like any other.
      unawaited(started.cdp.done.then((_) {
        if (!identical(_running, started)) return;
        _ended();
        unawaited(_quit("The browser was closed."));
      }));
      return started;
    }).whenComplete(() => _starting = null);
  }

  /// A hidden launch says it is headless in its user agent, which a site's
  /// bot check reads before anything else, so the first one asks the browser
  /// for its own and launches again with the word taken out — by flag rather
  /// than per tab, so a cross-site frame and a worker send it too.
  Future<_Running> _start(String exe, {required bool windowed}) async {
    if (windowed) return _launch(exe, _profile);
    final known = _userAgents[exe];
    if (known != null) {
      return _launch(exe, _profile, headless: true, userAgent: known);
    }
    final probe = await _launch(exe, _profile, headless: true);
    final agent =
        (await probe.cdp.send("Browser.getVersion"))["userAgent"] as String? ?? "";
    if (!agent.contains("HeadlessChrome")) {
      _userAgents[exe] = agent;
      return probe;
    }
    await _stop(probe);
    final fixed = agent.replaceAll("HeadlessChrome", "Chrome");
    _userAgents[exe] = fixed;
    return _launch(exe, _profile, headless: true, userAgent: fixed);
  }

  /// Quit; the next start is hidden again if that is the setting. What a
  /// sign-in typed goes too — not on [_quit] alone, which `browser_show`'s
  /// restart runs before reopening the very address that may carry it.
  @override
  Future<void> close({String why = "The user quit the browser."}) async {
    _ended();
    await _quit(why);
  }

  /// A launch in flight is waited out first, or it would come up on the
  /// profile being deleted; Windows will not delete a file a browser holds.
  @override
  Future<void> clearData() async {
    await _starting?.then((_) {}, onError: (_) {});
    await close(why: "The user deleted the browser's data: every site is "
        "signed out.");
    final profile = Directory(_profile);
    if (await profile.exists()) await profile.delete(recursive: true);
  }

  /// The browser is gone rather than restarting: the window it was shown
  /// in, what a sign-in typed, and a hide nobody gave back go with it.
  void _ended() {
    _shown = false;
    for (final tab in _tabs.values) {
      tab._secrets.clear();
      tab._signedIn.clear();
      // Not `unhide`: nobody gave it back, and the quit is the note.
      tab._hold.value = null;
    }
  }

  /// Every tab's page goes; each tab that had one hears [why], but
  /// [quietly], whose own call is the restart.
  Future<void> _quit(String why, {_CdpTab? quietly}) async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final running = _running;
    _running = null;
    _isRunning.value = false;
    for (final tab in _tabs.values) {
      tab._lose(identical(tab, quietly) ? null : why);
    }
    if (running != null) await _stop(running);
  }

  /// Quit the hidden browser so the next start comes up with a window.
  Future<void> _showWindow(_CdpTab by) async {
    if (_running?.windowed ?? false) return;
    await _quit("The browser restarted to open a window.", quietly: by);
    _shown = true;
  }

  String get _staging => p.join(browserDir, "downloads");

  /// Downloads land in [_staging] under the browser's own id for them, and
  /// are moved into the downloading tab's [_CdpTab.downloadDir] once whole:
  /// the behaviour is the browser's, not a tab's, so one directory per chat
  /// cannot be set on it. A hidden browser denies every download without it.
  Future<void> _watchDownloads(_Running running) async {
    final cdp = running.cdp;
    final begun = <String, Future<(_CdpTab?, String)>>{};
    cdp.events.where((e) => e.sessionId == null).listen((e) {
      final guid = e.params["guid"];
      if (guid is! String) return;
      if (e.method == "Browser.downloadWillBegin") {
        final name = "${e.params["suggestedFilename"] ?? ""}";
        begun[guid] = _tabOf(cdp, "${e.params["frameId"]}")
            .then((tab) => (tab, name), onError: (_) => (null, name));
      } else if (e.method == "Browser.downloadProgress") {
        final state = e.params["state"];
        if (state == "inProgress") return;
        final download = begun.remove(guid);
        if (download == null) return;
        unawaited(download.then((d) => state == "completed"
            ? _deliver(guid, d.$1, d.$2)
            : d.$1?._note("The download of ${d.$2} was cancelled.")));
      }
    });
    try {
      final staging = Directory(_staging);
      // What is left here is a download no tab could be found for, kept
      // until the next start.
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      await cdp.send("Browser.setDownloadBehavior", params: {
        "behavior": "allowAndName",
        "downloadPath": _staging,
        "eventsEnabled": true,
      });
    } catch (e) {
      logFailure(_tag, "downloads could not be routed", e);
    }
  }

  /// The tab [frameId] is in: its main frame (whose id is the tab's), a
  /// frame inside it, or a popup it opened to download from.
  Future<_CdpTab?> _tabOf(CdpConnection cdp, String frameId) async {
    _CdpTab? byTarget(String? target) => _tabs.values
        .where((tab) => tab._page != null && tab._page!.target == target)
        .firstOrNull;
    final direct = byTarget(frameId);
    if (direct != null) return direct;
    final targets = await cdp.send("Target.getTargets");
    for (final info in (targets["targetInfos"] as List? ?? const []).cast<Map>()) {
      if (info["targetId"] == frameId) {
        final opener = byTarget(info["openerId"] as String?);
        if (opener != null) return opener;
      }
    }
    bool holds(Map frame) =>
        (frame["frame"] as Map?)?["id"] == frameId ||
        (frame["childFrames"] as List? ?? const []).cast<Map>().any(holds);
    for (final tab in _tabs.values) {
      final page = tab._page;
      if (page == null) continue;
      try {
        final tree =
            await cdp.send("Page.getFrameTree", sessionId: page.session);
        if (holds(tree["frameTree"] as Map? ?? const {})) return tab;
      } on CdpException {
        // That tab is closing; the download is not from it.
      }
    }
    return null;
  }

  /// Move a finished download out of [_staging] under its own name, made
  /// unique beside what is already there.
  Future<void> _deliver(String guid, _CdpTab? tab, String suggested) async {
    final dir = tab?.downloadDir;
    final from = File(p.join(_staging, guid));
    if (tab == null || dir == null) {
      logFailure(_tag, "a download has no chat to go to; left at ${from.path}");
      return;
    }
    try {
      await Directory(dir).create(recursive: true);
      final name = p.basename(suggested.trim()).isEmpty
          ? "download"
          : p.basename(suggested.trim());
      var to = p.join(dir, name);
      for (var n = 1; await File(to).exists() || await Directory(to).exists(); n++) {
        to = p.join(dir, "${p.basenameWithoutExtension(name)} ($n)${p.extension(name)}");
      }
      try {
        await from.rename(to);
      } on FileSystemException {
        // The cache and the workspace may be on different filesystems.
        await from.copy(to);
        await from.delete();
      }
      tab._note("A download finished: ${p.basename(to)}, saved to "
          "downloads/${p.basename(to)} in your workspace.");
    } catch (e) {
      logFailure(_tag, "a download could not be moved into ${tab.chatId}'s "
          "workspace", e);
    }
  }

  /// One entry per name, the first that exists: a browser on `PATH` as both
  /// `google-chrome` and `google-chrome-stable` is one browser.
  @override
  Future<List<FoundBrowser>> detect() async {
    final found = <String, FoundBrowser>{};
    for (final (name, path) in _candidates()) {
      if (!found.containsKey(name) && await File(path).exists()) {
        found[name] = FoundBrowser(name, path);
      }
    }
    return [...found.values];
  }

  @override
  Future<String> verify(String picked) async {
    final exe = picked.endsWith(".app") ? macAppExecutable(picked) : picked;
    if (exe == null || !await File(exe).exists()) {
      throw CdpException("$picked is not a program this app can run.");
    }
    final probe = p.join(browserDir, "probe-$pid");
    try {
      final started = await _launch(exe, probe, headless: true);
      await started.cdp.send("Browser.getVersion");
      await _stop(started);
      return exe;
    } finally {
      try {
        await Directory(probe).delete(recursive: true);
      } catch (_) {}
    }
  }
}

class _Running {
  _Running(this.executable, this.process, this.cdp, {required this.windowed});

  final String executable;
  final Process process;
  final CdpConnection cdp;
  final bool windowed;
}

/// Ask the browser to quit, and kill it where it will not.
Future<void> _stop(_Running running) async {
  try {
    await running.cdp.send("Browser.close", timeout: const Duration(seconds: 5));
  } catch (_) {
    // Gone already, or not answering: the kill below covers both.
  }
  await running.cdp.close();
  await running.process.exitCode
      .timeout(const Duration(seconds: 5), onTimeout: () {
    running.process.kill(ProcessSignal.sigkill);
    return -1;
  });
}

/// Quit a browser still running on [profile] that nothing here drives: one an
/// app that quit or crashed left behind holds the profile's lock, and every
/// launch after it exits 21 until it goes. The lock is Chromium's
/// `SingletonLock`, a symlink to `<host>-<pid>` on Linux and macOS; Windows
/// has none to read. Only a process launched on this very profile is touched,
/// so the user's own browser never is.
Future<void> reapLostBrowser(String profile) async {
  if (Platform.isWindows) return;
  final lock = Link(p.join(profile, "SingletonLock"));
  final String held;
  try {
    held = await lock.target();
  } on FileSystemException {
    return;
  }
  final dash = held.lastIndexOf("-");
  if (dash < 0) return;
  final pid = int.tryParse(held.substring(dash + 1));
  if (pid == null || held.substring(0, dash) != Platform.localHostname) return;
  if (!(await _commandLine(pid)).contains("--user-data-dir=$profile")) return;
  logFailure(_tag, "quitting browser $pid left running on the profile");
  Process.killPid(pid);
  // A browser deletes its lock as it quits; a stale one it can take over.
  for (var i = 0; i < 50 && await _commandLine(pid) != ""; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (await _commandLine(pid) != "") Process.killPid(pid, ProcessSignal.sigkill);
}

/// [pid]'s command line, or empty where there is no such process.
Future<String> _commandLine(int pid) async {
  try {
    if (Platform.isLinux) {
      return (await File("/proc/$pid/cmdline").readAsString()).replaceAll("\x00", " ");
    }
    final ps = await Process.run("ps", ["-p", "$pid", "-o", "command="]);
    return ps.exitCode == 0 ? (ps.stdout as String).trim() : "";
  } catch (_) {
    return "";
  }
}

/// Start [exe] on [profile] with a DevTools port of its choosing, and connect.
/// The port is read from `DevToolsActivePort`, which the browser writes into
/// the profile once it listens: no port is guessed, so none can be taken.
Future<_Running> _launch(String exe, String profile,
    {bool headless = false, String? userAgent}) async {
  await Directory(profile).create(recursive: true);
  await reapLostBrowser(profile);
  final portFile = File(p.join(profile, "DevToolsActivePort"));
  if (await portFile.exists()) await portFile.delete();
  final process = await Process.start(
    exe,
    [
      "--remote-debugging-port=0",
      "--user-data-dir=$profile",
      "--no-first-run",
      "--no-default-browser-check",
      "--window-size=1280,900",
      // Remote debugging alone sets `navigator.webdriver`, window or none, and
      // it is the first thing a bot check reads.
      "--disable-blink-features=AutomationControlled",
      if (headless) "--headless=new",
      if (userAgent != null) "--user-agent=$userAgent",
      "about:blank",
    ],
    environment: environmentWithoutAppImage(),
    includeParentEnvironment: false,
  );
  // Drained, or a chatty browser fills the pipe and stalls; the tail is kept
  // for saying why one would not start.
  final stderr = <String>[];
  process.stdout.drain<void>().ignore();
  process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .listen((line) {
    stderr.add(line);
    if (stderr.length > 20) stderr.removeAt(0);
  });
  int? exited;
  unawaited(process.exitCode.then((code) => exited = code));

  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (true) {
    if (await portFile.exists()) {
      final lines = (await portFile.readAsString()).trim().split("\n");
      if (lines.length >= 2) {
        final url = Uri.parse("ws://127.0.0.1:${lines[0].trim()}${lines[1].trim()}");
        try {
          return _Running(exe, process, await CdpConnection.connect(url),
              windowed: !headless);
        } catch (error) {
          process.kill();
          throw CdpException("The browser would not take a connection: $error");
        }
      }
    }
    if (exited != null) {
      final why = stderr.isEmpty ? "" : ": ${stderr.last}";
      logFailure(_tag, "$exe exited $exited before listening$why");
      throw CdpException(exited == 0
          ? "The browser handed off to a copy already running on its profile. "
              "Quit that one and try again."
          : "The browser exited with $exited before it could be driven$why");
    }
    if (DateTime.now().isAfter(deadline)) {
      process.kill();
      throw const CdpException(
          "The browser did not open a DevTools port within 30 seconds. It may "
          "not be a Chromium-family browser.");
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Where the Chromium family installs itself, by the name a user knows each
/// one under. Firefox is not here: it speaks WebDriver BiDi rather than the
/// DevTools Protocol.
List<(String, String)> _candidates() {
  if (Platform.isLinux) {
    final path = (Platform.environment["PATH"] ?? "").split(":");
    return [
      for (final (name, bin) in const [
        ("Google Chrome", "google-chrome-stable"),
        ("Google Chrome", "google-chrome"),
        ("Chromium", "chromium"),
        ("Chromium", "chromium-browser"),
        ("Brave", "brave-browser"),
        ("Brave", "brave"),
        ("Microsoft Edge", "microsoft-edge-stable"),
        ("Microsoft Edge", "microsoft-edge"),
        ("Vivaldi", "vivaldi-stable"),
        ("Vivaldi", "vivaldi"),
        ("Helium", "helium"),
      ])
        for (final dir in path)
          if (dir.isNotEmpty) (name, p.join(dir, bin)),
    ];
  }
  if (Platform.isMacOS) {
    final home = Platform.environment["HOME"];
    return [
      for (final root in ["/Applications", if (home != null) "$home/Applications"])
        for (final (name, app, exe) in const [
          ("Google Chrome", "Google Chrome.app", "Google Chrome"),
          ("Chromium", "Chromium.app", "Chromium"),
          ("Brave", "Brave Browser.app", "Brave Browser"),
          ("Microsoft Edge", "Microsoft Edge.app", "Microsoft Edge"),
          ("Vivaldi", "Vivaldi.app", "Vivaldi"),
          ("Helium", "Helium.app", "Helium"),
        ])
          (name, p.join(root, app, "Contents", "MacOS", exe)),
    ];
  }
  if (Platform.isWindows) {
    final env = Platform.environment;
    return [
      for (final root in [
        env["ProgramFiles"],
        env["ProgramFiles(x86)"],
        env["LOCALAPPDATA"],
      ].nonNulls)
        for (final (name, exe) in const [
          ("Google Chrome", r"Google\Chrome\Application\chrome.exe"),
          ("Microsoft Edge", r"Microsoft\Edge\Application\msedge.exe"),
          ("Brave", r"BraveSoftware\Brave-Browser\Application\brave.exe"),
          ("Vivaldi", r"Vivaldi\Application\vivaldi.exe"),
          ("Chromium", r"Chromium\Application\chrome.exe"),
        ])
          (name, p.join(root, exe)),
    ];
  }
  return const [];
}

/// What [_CdpTab.snapshot] reads back from the page script.
class _Snapshot {
  _Snapshot(Map<String, dynamic> json)
      : title = json["title"] as String? ?? "",
        url = json["url"] as String? ?? "",
        scrollY = (json["scrollY"] as num?)?.toInt() ?? 0,
        height = (json["height"] as num?)?.toInt() ?? 0,
        width = (json["width"] as num?)?.toDouble() ?? 0,
        view = (json["view"] as num?)?.toDouble() ?? 0,
        elements = (json["elements"] as List? ?? const []).cast<String>(),
        text = json["text"] as String? ?? "",
        frames = (json["frames"] as List? ?? const []).cast<String>();

  final String title;
  final String url;
  final int scrollY;
  final int height;
  final double width;
  final double view;
  final List<String> elements;
  final String text;
  final List<String> frames;
}

/// How much of a page one answer carries: a viewport's worth is what the model
/// reads after every action, the whole page a chunk at a time.
const _viewElements = 150;
const _viewText = 6000;
const _pageElements = 400;
const pageTextChunk = 15000;

/// One chat's tab: opened on first use, and opened again if the user closes it.
class _CdpTab implements BrowserTab {
  _CdpTab(this._browser, this.chatId) {
    _shown.addListener(_browser._tabsChanged);
  }

  final CdpBrowser _browser;
  final String chatId;

  ({String target, String session})? _page;
  var _pointer = (x: 0.0, y: 0.0);
  final _random = Random();

  /// The agent's last click, in viewport coordinates, until a navigation or
  /// scroll moves the page out from under it.
  ({double x, double y})? _lastClick;

  final _shown = ValueNotifier<BrowserPage?>(null);
  var _opened = 0;

  @override
  ValueListenable<BrowserPage?> get page => _shown;

  void _forget() {
    _page = null;
    _world = null;
    _shown.value = null;
  }

  /// The browser quit under this tab: what waited on its page ends, and the
  /// agent hears [why] where it had a page to lose.
  void _lose(String? why) {
    final had = _page != null;
    // Forgotten first, so the upload's cancel sends nothing to a closing tab.
    _forget();
    if (had && why != null) {
      _note("$why Your tab and its page are gone; the next browser call "
          "starts it again on a blank tab.");
    }
    _endRequest(const CredentialsDeclined(
        "The browser was quit before the sign-in was filled in."));
    cancelUpload(why: "The browser was quit before files were chosen.");
  }

  /// The page script's world in the current document, made once per
  /// document: each one made lives until the page navigates.
  int? _world;

  final _notes = <String>[];

  /// The user clicked or typed in the page: one note however much they
  /// did, and never what they typed, which may be private.
  bool _handled = false;

  /// Scrubbed as it is written: an address can carry what a sign-in typed,
  /// and the values are dropped at the quit that may itself be noted.
  void _note(String note) => _notes.add(_scrub(note));

  @override
  List<String> takeNotes() {
    final notes = [
      ..._notes,
      if (_handled) "The user clicked or typed in the page themselves.",
    ];
    _notes.clear();
    _handled = false;
    return notes;
  }

  Future<({CdpConnection cdp, String target, String session})> _attach() async {
    final running = await _browser._ensure();
    final cdp = running.cdp;
    var page = _page;
    if (page == null) {
      final created =
          await cdp.send("Target.createTarget", params: {"url": "about:blank"});
      final target = created["targetId"] as String;
      final attached = await cdp.send("Target.attachToTarget",
          params: {"targetId": target, "flatten": true});
      final session = attached["sessionId"] as String;
      await cdp.send("Page.enable", sessionId: session);
      // A passkey request opens Chrome's own dialog, which takes input from
      // the page — and a hidden browser has nowhere to draw it, so the page
      // looks fine and swallows every click ("Try another way" included).
      // The protocol's virtual authenticators with no UI stand in: the
      // request waits silently, and the page stays the user's. A windowed
      // browser keeps the real dialog, which is how a passkey is used.
      if (!running.windowed) {
        try {
          await cdp.send("WebAuthn.enable",
              params: {"enableUI": false}, sessionId: session);
        } catch (e) {
          logFailure(_tag, "passkeys could not be kept off a hidden tab", e);
        }
      }
      page = (target: target, session: session);
      _page = page;
      _shown.value = BrowserPage(url: "about:blank", opened: ++_opened);
      // The user closing the tab is the tab gone; the next call opens another.
      // A navigation moves the chip's address as it happens, rather than only
      // when the agent next reads the page.
      final sub = cdp.events
          .where((e) => e.sessionId == session || e.sessionId == null)
          .listen(null);
      sub.onData((e) {
        if ((e.method == "Target.detachedFromTarget" &&
                e.params["sessionId"] == session) ||
            (e.method == "Target.targetDestroyed" &&
                e.params["targetId"] == target)) {
          if (_page?.session == session) _forget();
          sub.cancel();
        } else if (e.method == "Page.frameNavigated" && _page?.session == session) {
          final frame = e.params["frame"] as Map? ?? const {};
          if (frame["parentId"] == null) {
            _world = null;
            _shown.value = _shown.value?.copyWith(url: "${frame["url"]}");
          }
        }
      });
    }
    // In front, or Chrome throttles it and a screenshot of it never comes.
    await cdp.send("Target.activateTarget", params: {"targetId": page.target});
    return (cdp: cdp, target: page.target, session: page.session);
  }

  Future<dynamic> _eval(String expression) async {
    for (var attempt = 0;; attempt++) {
      final page = await _attach();
      final reused = _world != null;
      try {
        final world = _world ??= (await page.cdp.send(
            "Page.createIsolatedWorld",
            params: {"frameId": page.target, "worldName": "entoli"},
            sessionId: page.session))["executionContextId"] as int;
        final result = await page.cdp.send("Runtime.evaluate",
            params: {
              // The script defines itself once per world.
              "expression": "$pageScript\n$expression",
              "contextId": world,
              "returnByValue": true,
              "awaitPromise": true,
            },
            sessionId: page.session);
        final thrown = result["exceptionDetails"] as Map?;
        if (thrown != null) {
          throw _ScriptError(
              "${(thrown["exception"] as Map?)?["description"] ?? thrown["text"]}");
        }
        return (result["result"] as Map?)?["value"];
      } on CdpException {
        // A navigation took the frame or its world mid-call; the next
        // document answers once it is there. A kept world that is gone is
        // just made again.
        _world = null;
        if (attempt >= 3) rethrow;
        if (!reused) await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  Future<_Snapshot> _snapshot({required bool all}) async => _Snapshot(
      jsonDecode(await _eval("window.__entoli.snapshot($all)") as String)
          as Map<String, dynamic>);

  /// Run [action], then wait for whatever it started: a navigation to load,
  /// or just the page to settle.
  Future<void> _act(Future<void> Function() action) async {
    final page = await _attach();
    final started = Completer<void>();
    final loaded = Completer<void>();
    final sub = page.cdp.events.where((e) => e.sessionId == page.session).listen((e) {
      if (e.method == "Page.frameStartedLoading" &&
          e.params["frameId"] == page.target &&
          !started.isCompleted) {
        started.complete();
      } else if (e.method == "Page.loadEventFired" && !loaded.isCompleted) {
        loaded.complete();
      }
    });
    try {
      await action();
      await Future.any(
          [started.future, Future<void>.delayed(const Duration(milliseconds: 700))]);
      if (started.isCompleted) {
        await loaded.future.timeout(const Duration(seconds: 20), onTimeout: () {});
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } finally {
      await sub.cancel();
    }
  }

  /// Glide to ([x], [y]) in a few uneven steps, as a hand would, rather than
  /// arriving from nowhere.
  Future<void> _moveTo(double x, double y) async {
    final page = await _attach();
    final from = _pointer;
    final steps = 6 + _random.nextInt(6);
    final bend = (_random.nextDouble() - 0.5) * 60;
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      final eased = t * t * (3 - 2 * t);
      final arc = sin(pi * t) * bend;
      await page.cdp.send("Input.dispatchMouseEvent",
          params: {
            "type": "mouseMoved",
            "x": from.x + (x - from.x) * eased + arc,
            "y": from.y + (y - from.y) * eased - arc,
          },
          sessionId: page.session);
      await Future<void>.delayed(Duration(milliseconds: 8 + _random.nextInt(18)));
    }
    _pointer = (x: x, y: y);
  }

  Future<void> _button(String type, double x, double y) async {
    final page = await _attach();
    await page.cdp.send("Input.dispatchMouseEvent",
        params: {
          "type": type,
          "x": x,
          "y": y,
          "button": "left",
          "buttons": type == "mousePressed" ? 1 : 0,
          "clickCount": 1,
        },
        sessionId: page.session);
  }

  Future<void> _clickAt(double x, double y) async {
    _lastClick = (x: x, y: y);
    await _moveTo(x, y);
    await _button("mousePressed", x, y);
    await Future<void>.delayed(Duration(milliseconds: 40 + _random.nextInt(80)));
    await _button("mouseReleased", x, y);
  }

  Future<Map<String, dynamic>> _rect(int ref) async {
    final json = await _eval("window.__entoli.rect($ref)");
    if (json == null) {
      throw CdpException("There is no element [$ref] on this page any more. "
          "Read the page again for the current numbers.");
    }
    return jsonDecode(json as String) as Map<String, dynamic>;
  }

  /// Click [ref] off its exact centre, the way a pointer lands.
  Future<void> _clickRef(int ref) async {
    final rect = await _rect(ref);
    double near(String start, String size) =>
        (rect[start] as num) +
        (rect[size] as num) * (0.4 + _random.nextDouble() * 0.2);
    await _clickAt(near("left", "width"), near("top", "height"));
  }

  @override
  Future<String> goto(String url) async {
    final target = pageAddress(url);
    final page = await _attach();
    _lastClick = null;
    String? error;
    await _act(() async {
      final result = await page.cdp.send("Page.navigate",
          params: {"url": target}, sessionId: page.session);
      error = result["errorText"] as String?;
    });
    if (error != null && error!.isNotEmpty) {
      throw CdpException("The page did not load: $error");
    }
    return _describeView();
  }

  @override
  Future<String> back() async {
    final page = await _attach();
    _lastClick = null;
    String? to;
    await _act(() async => to = await _go(page.cdp, page.session, -1));
    if (to == null) {
      return "There is no earlier page in this tab.\n\n${await _describeView()}";
    }
    return _describeView();
  }

  /// Move [by] entries through the tab's history; the address moved to, or
  /// null where there is none that far.
  static Future<String?> _go(CdpConnection cdp, String session, int by) async {
    final history =
        await cdp.send("Page.getNavigationHistory", sessionId: session);
    final to = (history["currentIndex"] as int) + by;
    final entries = history["entries"] as List;
    if (to < 0 || to >= entries.length) return null;
    final entry = entries[to] as Map;
    await cdp.send("Page.navigateToHistoryEntry",
        params: {"entryId": entry["id"]}, sessionId: session);
    return "${entry["url"]}";
  }

  @override
  Future<String> click({int? ref, double? x, double? y}) async {
    if (ref != null) {
      await _act(() => _clickRef(ref));
    } else if (x != null && y != null) {
      await _act(() => _clickAt(x, y));
    } else {
      throw const CdpException("Give the element's number, or x and y.");
    }
    return _describeView();
  }

  @override
  Future<String> drag(
      ({double x, double y}) from, ({double x, double y}) to) async {
    await _act(() async {
      await _moveTo(from.x, from.y);
      await _button("mousePressed", from.x, from.y);
      final page = await _attach();
      final steps = 15 + _random.nextInt(10);
      for (var i = 1; i <= steps; i++) {
        final t = i / steps;
        // Quick to start, slow to settle, with a tremble.
        final eased = 1 - pow(1 - t, 3).toDouble();
        final x = from.x + (to.x - from.x) * eased;
        final y = from.y + (to.y - from.y) * eased + (_random.nextDouble() - 0.5) * 2;
        await page.cdp.send("Input.dispatchMouseEvent",
            params: {"type": "mouseMoved", "x": x, "y": y, "button": "left", "buttons": 1},
            sessionId: page.session);
        await Future<void>.delayed(Duration(milliseconds: 12 + _random.nextInt(25)));
      }
      await _button("mouseReleased", to.x, to.y);
      _pointer = to;
    });
    return _describeView();
  }

  @override
  Future<String> type(int? ref, String text, {bool submit = false}) async {
    if (ref != null) {
      await _fill(ref, text, submit: submit);
    } else {
      await _typeAtFocus(text);
      if (submit) {
        final page = await _attach();
        await _act(() => _stroke(page.cdp, page.session, "Enter"));
      }
    }
    return _describeView();
  }

  /// [text] key by key at whatever has focus. An editor that draws its
  /// text — Google Docs, Slides — reads keys from a hidden field it moved
  /// focus to, so a key press is what reaches it where an inserted string
  /// does not. A newline is Enter.
  Future<void> _typeAtFocus(String text) async {
    final page = await _attach();
    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      await _stroke(page.cdp, page.session, char == "\n" ? "Enter" : char);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  /// Press and release [name], a key [domKey] knows. Held Control or Meta
  /// makes a letter a shortcut: no text goes in, and an editing one names
  /// its command, which a synthesized key does not run on its own.
  static Future<void> _stroke(CdpConnection cdp, String session, String name,
      {Set<String> modifiers = const {}}) async {
    final found = domKey(name) ??
        (throw CdpException("\"$name\" is not a key this can press. Use a "
            "DOM key name (Enter, Tab, Escape, ArrowDown, F5) or one character."));
    final shortcut = modifiers.contains("Control") || modifiers.contains("Meta");
    final command = shortcut
        ? editingCommand(found.key, shift: modifiers.contains("Shift"))
        : null;
    final text = shortcut || modifiers.contains("Alt") ? null : found.text;
    for (final down in [true, false]) {
      await _sendKey(
          cdp,
          session,
          BrowserKey(
            down: down,
            key: found.key,
            code: found.code,
            keyCode: found.keyCode,
            text: text,
            modifiers: domModifiers(modifiers),
            commands: [?command],
          ));
    }
  }

  static Future<void> _sendKey(
          CdpConnection cdp, String session, BrowserKey event) =>
      cdp.send("Input.dispatchKeyEvent",
          params: {
            // `keyDown` with text inserts it; `rawKeyDown` is a press that
            // inserts nothing, which a shortcut or an arrow is.
            "type": event.down
                ? (event.text == null ? "rawKeyDown" : "keyDown")
                : "keyUp",
            "key": event.key,
            "code": event.code,
            "windowsVirtualKeyCode": event.keyCode,
            "modifiers": event.modifiers,
            if (event.down && event.text != null) ...{
              "text": event.text,
              "unmodifiedText": event.text,
            },
            if (event.down && event.commands.isNotEmpty)
              "commands": event.commands,
          },
          sessionId: session);

  @override
  Future<String> press(String key, {Set<String> modifiers = const {}}) async {
    final page = await _attach();
    await _act(() => _stroke(page.cdp, page.session, key, modifiers: modifiers));
    return _describeView();
  }

  Future<void> _fill(int ref, String text, {bool submit = false}) async {
    final chosen = await _eval("window.__entoli.choose($ref, ${jsonEncode(text)})");
    if (chosen == "none") {
      throw CdpException("[$ref] has no option matching \"$text\".");
    }
    if (chosen == null) {
      await _clickRef(ref);
      await _eval("window.__entoli.selectContents($ref)");
      final page = await _attach();
      if (text.isEmpty) {
        await _stroke(page.cdp, page.session, "Backspace");
      } else {
        await page.cdp.send("Input.insertText",
            params: {"text": text}, sessionId: page.session);
      }
    }
    if (submit) {
      final page = await _attach();
      await _act(() => _stroke(page.cdp, page.session, "Enter"));
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  final _hold = ValueNotifier<BrowserHold?>(null);
  final _request = ValueNotifier<CredentialRequest?>(null);
  Completer<String>? _waiting;

  /// A sign-in being typed in: no screenshot until it is through, so no
  /// picture of it half-typed reaches the agent.
  bool _filling = false;

  /// What the user signed in with, until the browser quits: a page
  /// echoes it — an address with the password in its query, the email
  /// put back in a field after a failed login, "Signed in as" — so every
  /// text the agent is answered with has it taken out, raw and URL-encoded.
  /// Held in memory alone, and dropped at the quit. Short values are not
  /// held: a two-letter one would blank out half the page.
  final _secrets = <String>{};

  /// The sites a sign-in was filled in on, until the browser quits. Text is
  /// scrubbed of what was typed; a picture cannot be, and a sign-in page
  /// shows it back (the account chip on Google's password step, the email
  /// put back after a failed login), so no screenshot is taken on one.
  final _signedIn = <String>{};

  String _scrub(String text) {
    for (final secret in _secrets) {
      for (final form in {
        secret,
        Uri.encodeQueryComponent(secret),
        Uri.encodeComponent(secret),
      }) {
        text = text.replaceAll(form, "(hidden)");
      }
    }
    return text;
  }

  @override
  ValueListenable<BrowserHold?> get hold => _hold;

  /// The agent's own hide is its call, so it is not noted back to it; the
  /// giving back always is the user's.
  @override
  void hide(BrowserHold hold) {
    if (_hold.value != null) return;
    _hold.value = hold;
    if (!hold.byAgent) _note("The user hid the browser from you.");
  }

  @override
  void unhide() {
    if (_hold.value == null) return;
    _hold.value = null;
    _note("The user gave the browser back to you.");
  }

  @override
  ValueListenable<CredentialRequest?> get credentialRequest => _request;

  @override
  Future<String> requestCredentials(CredentialRequest request) {
    _waiting?.completeError(
        const CredentialsDeclined("A newer sign-in request replaced this one."));
    final waiting = Completer<String>();
    _waiting = waiting;
    _request.value = request;
    return waiting.future;
  }

  @override
  Future<void> submitCredentials(List<String> values) async {
    final request = _request.value;
    final waiting = _waiting;
    if (request == null || waiting == null) return;
    _request.value = null;
    _waiting = null;
    _filling = true;
    _secrets.addAll(values.map((v) => v.trim()).where((v) => v.length >= 4));
    try {
      _signedIn.add(await _eval("location.origin") as String);
      for (var i = 0; i < request.fields.length; i++) {
        final field = request.fields[i];
        // Marked before it is typed in, so no description of the page ever
        // carries it.
        await _eval("window.__entoli.markSecret(${field.ref})");
        try {
          await _fill(field.ref, i < values.length ? values[i] : "");
        } catch (_) {
          // What failed may name what was typed; the agent hears which
          // field, and nothing of it.
          throw CdpException("The \"${field.label}\" field [${field.ref}] could "
              "not be filled in: it may have gone from the page.");
        }
      }
      for (final click in request.submit) {
        await _act(() async {
          if (click.ref != null) {
            await _clickRef(click.ref!);
          } else if (click.x != null && click.y != null) {
            await _clickAt(click.x!, click.y!);
          }
        });
      }
      _filling = false;
      waiting.complete("The user filled in the sign-in and it was submitted; "
          "what they typed is not shown to you.\n\n${await _describeView()}");
    } catch (e) {
      _filling = false;
      if (!waiting.isCompleted) waiting.completeError(e);
    }
  }

  @override
  void declineCredentials() => _endRequest(
      const CredentialsDeclined("The user declined to sign in here."));

  @override
  void cancelCredentials() =>
      _endRequest(const CredentialsDeclined("The turn was stopped."));

  void _endRequest(CredentialsDeclined why) {
    final waiting = _waiting;
    _request.value = null;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.completeError(why);
  }

  final _upload = ValueNotifier<UploadRequest?>(null);
  Completer<String>? _uploadWaiting;

  /// The file field the waiting chooser belongs to, by the protocol's id for
  /// it, which outlives the chooser's interception.
  int? _chooser;

  @override
  ValueListenable<UploadRequest?> get uploadRequest => _upload;

  /// Click [ref] with the page's file choosers caught, and answer with the
  /// one the click opened: no dialog is drawn, so nothing waits on a person
  /// at a window the browser may not have.
  Future<({int node, bool multiple, String target, String url})> _openChooser(
      int ref) async {
    final page = await _attach();
    final target = await describeTarget(ref: ref);
    final opened = Completer<Map<String, dynamic>>();
    final sub = page.cdp.events
        .where((e) =>
            e.sessionId == page.session && e.method == "Page.fileChooserOpened")
        .listen((e) {
      if (!opened.isCompleted) opened.complete(e.params);
    });
    await page.cdp.send("Page.setInterceptFileChooserDialog",
        params: {"enabled": true}, sessionId: page.session);
    try {
      await _clickRef(ref);
      final chooser = await opened.future.timeout(const Duration(seconds: 10),
          onTimeout: () => throw CdpException(
              "Clicking [$ref] opened no file chooser. Give the number of the "
              "upload button or the file field itself."));
      final node = chooser["backendNodeId"];
      if (node is! int) {
        throw const CdpException("The file chooser names no field to fill.");
      }
      return (
        node: node,
        multiple: chooser["mode"] == "selectMultiple",
        target: target,
        url: (await _eval("location.href") as String?) ?? "",
      );
    } finally {
      await sub.cancel();
      try {
        await page.cdp.send("Page.setInterceptFileChooserDialog",
            params: {"enabled": false}, sessionId: page.session);
      } catch (_) {
        // The tab went with the click; there is nothing to switch off.
      }
    }
  }

  Future<void> _fillChooser(int node, List<String> paths) async {
    final page = await _attach();
    await page.cdp.send("DOM.setFileInputFiles",
        params: {"files": paths, "backendNodeId": node}, sessionId: page.session);
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  static String _named(List<String> paths) =>
      paths.map((path) => p.basename(path)).join(", ");

  @override
  Future<String> upload(int ref, List<String> paths) async {
    final chooser = await _openChooser(ref);
    if (!chooser.multiple && paths.length > 1) {
      await _cancelChooser(chooser.node);
      throw CdpException("[$ref] takes one file; ${paths.length} were given.");
    }
    await _fillChooser(chooser.node, paths);
    return "Uploaded ${_named(paths)} into ${chooser.target}.\n\n"
        "${await _describeView()}";
  }

  @override
  Future<String> requestUpload(int ref) async {
    final chooser = await _openChooser(ref);
    cancelUpload(why: "A newer upload replaced this one.");
    final waiting = Completer<String>();
    _uploadWaiting = waiting;
    _chooser = chooser.node;
    _upload.value = UploadRequest(
        target: chooser.target, url: chooser.url, multiple: chooser.multiple);
    return waiting.future;
  }

  @override
  Future<void> submitUpload(List<String> paths) async {
    final waiting = _uploadWaiting;
    final node = _chooser;
    if (waiting == null || node == null || paths.isEmpty) return;
    _upload.value = null;
    _uploadWaiting = null;
    _chooser = null;
    try {
      await _fillChooser(node, paths);
      waiting.complete("The user chose ${paths.length} file(s) and they were "
          "given to the page: ${_named(paths)}.\n\n${await _describeView()}");
    } catch (e) {
      if (!waiting.isCompleted) waiting.completeError(e);
    }
  }

  @override
  void cancelUpload({String why = "The user cancelled the upload."}) {
    final waiting = _uploadWaiting;
    final node = _chooser;
    if (waiting == null) return;
    _upload.value = null;
    _uploadWaiting = null;
    _chooser = null;
    if (node != null) unawaited(_cancelChooser(node));
    if (!waiting.isCompleted) waiting.completeError(UploadCancelled(why));
  }

  /// What dismissing the dialog would have told the page: a `cancel` on the
  /// field, which a page waiting on its chooser listens for.
  Future<void> _cancelChooser(int node) async {
    final live = _live;
    if (live == null) return;
    try {
      final resolved = await live.cdp.send("DOM.resolveNode",
          params: {"backendNodeId": node}, sessionId: live.session);
      final object = (resolved["object"] as Map?)?["objectId"];
      if (object == null) return;
      await live.cdp.send("Runtime.callFunctionOn",
          params: {
            "objectId": object,
            "functionDeclaration":
                "function() { this.dispatchEvent(new Event('cancel', {bubbles: true})); }",
          },
          sessionId: live.session);
    } catch (e) {
      logFailure(_tag, "a file chooser could not be cancelled", e);
    }
  }

  @override
  Future<String> scroll({bool up = false}) async {
    final before = await _snapshot(all: false);
    final page = await _attach();
    _lastClick = null;
    final x = before.width / 2, y = before.view / 2;
    await _moveTo(x, y);
    await page.cdp.send("Input.dispatchMouseEvent",
        params: {
          "type": "mouseWheel",
          "x": x,
          "y": y,
          "deltaX": 0,
          "deltaY": (up ? -1 : 1) * before.view * 0.85,
        },
        sessionId: page.session);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return _describeView();
  }

  @override
  Future<String> pageText({int offset = 0}) async {
    final page = await _snapshot(all: true);
    final text = page.text;
    final start = offset.clamp(0, text.length);
    final end = min(text.length, start + pageTextChunk);
    final out = StringBuffer()
      ..writeln(page.title)
      ..writeln(page.url)
      ..writeln();
    if (start == 0) {
      out.writeln("Elements:");
      for (final line in page.elements.take(_pageElements)) {
        out.writeln(line);
      }
      if (page.elements.length > _pageElements) {
        out.writeln("…and ${page.elements.length - _pageElements} more.");
      }
      out.writeln();
    }
    out
      ..writeln("Text, characters $start–$end of ${text.length}:")
      ..writeln(text.substring(start, end));
    if (end < text.length) {
      out
        ..writeln()
        ..writeln("More follows: call again with offset $end.");
    }
    return _scrub(out.toString().trimRight());
  }

  /// Reopened at the page this tab was on: a hidden browser has no window to
  /// raise, so it is quit and started again with one, on the same profile —
  /// the cookies a check leaves are kept for when it is hidden again.
  @override
  Future<String> show({bool byUser = false}) async {
    if (_browser._running?.windowed ?? false) {
      await _attach();
      return "The browser window is open.";
    }
    String? url;
    if (_page != null) {
      try {
        url = await _eval("location.href") as String?;
      } catch (_) {
        // Nothing to come back to: the window opens blank.
      }
    }
    await _browser._showWindow(this);
    if (byUser) {
      _note("The user opened the browser in a window, which reloaded the "
          "page.");
    }
    if (url == null || url == "about:blank") {
      await _attach();
      return "The browser window is open.";
    }
    return goto(url);
  }

  @override
  Future<BrowserShot> screenshot({int? ref, bool markClick = false}) async {
    if (_filling) {
      throw const CdpException(
          "A sign-in is being typed in; no screenshot until it is through.");
    }
    final Map<String, dynamic> clip;
    double left = 0, top = 0;
    final page = await _attach();
    final [ratio as num, origin as String] =
        await _eval("[devicePixelRatio, location.origin]") as List;
    if (_signedIn.contains(origin)) {
      throw CdpException("No screenshot on $origin: the user signed in "
          "there, and the page may show what they typed. Read it with "
          "browser_page_text instead.");
    }
    // The clip's scale multiplies device pixels. Undone, a pixel in the image
    // is a CSS pixel in the viewport, which is what a click takes — on a
    // HiDPI screen it would otherwise be off by the ratio.
    final scale = 1 / ratio;
    if (ref != null) {
      final rect = await _rect(ref);
      left = (rect["left"] as num).toDouble();
      top = (rect["top"] as num).toDouble();
      // Document coordinates: the viewport's position plus the scroll.
      clip = {
        "x": left + (rect["scrollX"] as num),
        "y": top + (rect["scrollY"] as num),
        "width": rect["width"],
        "height": rect["height"],
        "scale": scale,
      };
    } else {
      final metrics =
          await page.cdp.send("Page.getLayoutMetrics", sessionId: page.session);
      final view = metrics["cssVisualViewport"] as Map;
      clip = {
        "x": view["pageX"],
        "y": view["pageY"],
        "width": view["clientWidth"],
        "height": view["clientHeight"],
        "scale": scale,
      };
    }
    final click = markClick ? _lastClick : null;
    // Drawn into the page for the one capture, from the isolated world, so
    // the page's own scripts hold no reference to it.
    if (click != null) {
      await _eval("""(() => {
        const dot = window.__entoliDot = document.createElement("div");
        dot.style.cssText = "position:fixed;left:${click.x - 6}px;"
          + "top:${click.y - 6}px;width:12px;height:12px;border-radius:50%;"
          + "background:red;border:2px solid white;box-sizing:border-box;"
          + "z-index:2147483647;pointer-events:none";
        document.documentElement.append(dot);
      })()""");
    }
    final Map<String, dynamic> shot;
    try {
      shot = await page.cdp.send("Page.captureScreenshot",
          params: {"format": "png", "clip": clip, "captureBeyondViewport": false},
          sessionId: page.session);
    } finally {
      if (click != null) await _eval("window.__entoliDot?.remove()");
    }
    return BrowserShot(base64Decode(shot["data"] as String),
        left: left, top: top, click: click);
  }

  @override
  Future<String> describeTarget({int? ref, double? x, double? y}) async {
    final what = await _eval("window.__entoli.line(${ref ?? "null"}, "
        "${x ?? "null"}, ${y ?? "null"})");
    final where = await _eval("location.href");
    final at = ref == null && x != null ? " at ($x, $y)" : "";
    return _scrub("${what ?? "nothing"}$at on $where");
  }

  /// The cross-site frames in this tab, by URL. They run in processes of
  /// their own, and a challenge widget puts its frame in a closed shadow root
  /// besides, so the page script never sees them; the browser's target list
  /// does. A frame's parent is the tab's main frame, whose id is the tab's.
  Future<List<String>> _foreignFrames() async {
    final page = await _attach();
    final targets = await page.cdp.send("Target.getTargets");
    return [
      for (final info in (targets["targetInfos"] as List? ?? const []).cast<Map>())
        if (info["type"] == "iframe" && info["parentFrameId"] == page.target)
          "${info["url"]}",
    ];
  }

  /// The open tab's session, or null: what the user's input goes to. Never
  /// launches, and does not bring the tab to the front per event — a mouse
  /// move is too frequent for a second round trip.
  ({CdpConnection cdp, String session})? get _live {
    final page = _page;
    final running = _browser._running;
    if (page == null || running == null || running.cdp.isClosed) return null;
    _browser._touch();
    return (cdp: running.cdp, session: page.session);
  }

  @override
  Future<void> historyBack() => _step(-1, "went back");

  @override
  Future<void> forward() => _step(1, "went forward");

  /// Move [by] entries through the tab's history, as the user.
  Future<void> _step(int by, String did) async {
    final live = _live;
    if (live == null) return;
    final to = await _go(live.cdp, live.session, by);
    // No full stop after the address, which would read as part of it.
    if (to != null) _note("The user $did to: $to");
  }

  @override
  Future<void> reload() async {
    final live = _live;
    if (live == null) return;
    await live.cdp.send("Page.reload", sessionId: live.session);
    _note("The user reloaded the page.");
  }

  @override
  Future<void> pointer(BrowserPointer event) async {
    final live = _live;
    if (live == null) return;
    final type = switch (event.kind) {
      BrowserPointerKind.move => "mouseMoved",
      BrowserPointerKind.down => "mousePressed",
      BrowserPointerKind.up => "mouseReleased",
      BrowserPointerKind.wheel => "mouseWheel",
    };
    await live.cdp.send("Input.dispatchMouseEvent",
        params: {
          "type": type,
          "x": event.x,
          "y": event.y,
          "button": event.button,
          "buttons": event.buttons,
          "clickCount": event.clickCount,
          "modifiers": event.modifiers,
          if (event.kind == BrowserPointerKind.wheel) ...{
            "deltaX": event.deltaX,
            "deltaY": event.deltaY,
          },
        },
        sessionId: live.session);
    // The agent's next glide starts where the user left the pointer.
    _pointer = (x: event.x, y: event.y);
    if (event.kind != BrowserPointerKind.move) _handled = true;
  }

  @override
  Future<void> key(BrowserKey event) async {
    final live = _live;
    if (live == null) return;
    await _sendKey(live.cdp, live.session, event);
    _handled = true;
  }

  @override
  Future<void> insertText(String text) async {
    final live = _live;
    if (live == null) return;
    await live.cdp.send("Input.insertText",
        params: {"text": text}, sessionId: live.session);
    _handled = true;
  }

  @override
  String? downloadDir;

  /// A field's selection is not the document's, so the focused one is asked
  /// first. Not through [_eval], which would start a closed browser.
  @override
  Future<String?> selectedText() async {
    final live = _live;
    if (live == null) return null;
    final result = await live.cdp.send("Runtime.evaluate",
        params: {
          "expression": """(() => {
  const a = document.activeElement;
  if (a && /^(INPUT|TEXTAREA)\$/.test(a.tagName) && a.type !== "password") {
    try {
      if (typeof a.selectionStart === "number") {
        return a.value.slice(a.selectionStart, a.selectionEnd);
      }
    } catch (_) {}
  }
  return String(getSelection());
})()""",
          "returnByValue": true,
        },
        sessionId: live.session);
    final text = (result["result"] as Map?)?["value"];
    return text is String && text.isNotEmpty ? text : null;
  }

  /// The screencast: Chrome sends a frame whenever the page repaints, hidden
  /// or not, and waits for each to be acknowledged before the next, so a slow
  /// viewer slows the stream rather than queueing it. Started on listen and
  /// stopped on cancel, so nothing is encoded while nobody watches.
  @override
  Stream<BrowserFrame> frames() {
    final controller = StreamController<BrowserFrame>();
    StreamSubscription<CdpEvent>? sub;
    ({CdpConnection cdp, String session})? casting;
    controller.onListen = () async {
      final page = _page;
      final running = _browser._running;
      if (page == null || running == null) {
        await controller.close();
        return;
      }
      final cdp = running.cdp;
      casting = (cdp: cdp, session: page.session);
      // The tab closing with the browser still up ends the stream too.
      final opened = _shown.value?.opened;
      void closed() {
        if (_shown.value?.opened == opened) return;
        _shown.removeListener(closed);
        unawaited(controller.close());
      }

      _shown.addListener(closed);
      controller.done.then((_) => _shown.removeListener(closed)).ignore();
      sub = cdp.events
          .where((e) =>
              e.sessionId == page.session && e.method == "Page.screencastFrame")
          .listen((e) {
        final meta = e.params["metadata"] as Map? ?? const {};
        controller.add(BrowserFrame(
          base64Decode(e.params["data"] as String),
          width: (meta["deviceWidth"] as num?)?.toDouble() ?? 0,
          height: (meta["deviceHeight"] as num?)?.toDouble() ?? 0,
        ));
        cdp
            .send("Page.screencastFrameAck",
                params: {"sessionId": e.params["sessionId"]},
                sessionId: page.session)
            .ignore();
      }, onDone: controller.close);
      try {
        await cdp.send("Page.startScreencast",
            params: {
              "format": "jpeg",
              "quality": 70,
              "maxWidth": 1280,
              "maxHeight": 900,
            },
            sessionId: page.session);
      } catch (_) {
        await controller.close();
      }
    };
    controller.onCancel = () async {
      await sub?.cancel();
      final on = casting;
      if (on != null && !on.cdp.isClosed) {
        try {
          await on.cdp.send("Page.stopScreencast", sessionId: on.session);
        } catch (_) {
          // The tab went first: there is nothing to stop.
        }
      }
    };
    return controller.stream;
  }

  Future<String> _describeView() async {
    final page = await _snapshot(all: false);
    _shown.value = _shown.value?.copyWith(url: page.url, title: page.title);
    final out = StringBuffer()
      ..writeln(page.title.isEmpty ? "(untitled)" : page.title)
      ..writeln(page.url)
      ..writeln("Showing ${page.scrollY}–${page.scrollY + page.view.round()} "
          "of ${page.height} px.");
    out
      ..writeln()
      ..writeln("Elements in view:");
    if (page.elements.isEmpty) out.writeln("(none)");
    for (final line in page.elements.take(_viewElements)) {
      out.writeln(line);
    }
    final text = page.text.length > _viewText
        ? "${page.text.substring(0, _viewText)}…"
        : page.text;
    out
      ..writeln()
      ..writeln("Text in view:")
      ..writeln(text.isEmpty ? "(none)" : text);
    final foreign = await _foreignFrames();
    if (foreign.isNotEmpty) {
      final hosts = {for (final url in foreign) Uri.tryParse(url)?.host ?? url};
      out
        ..writeln()
        ..writeln("Frames from other sites, unnumbered: ${hosts.join(", ")}");
    }
    if (looksLikeChallenge(
        page.title, page.text, [...page.frames, ...foreign])) {
      out
        ..writeln()
        ..writeln(challengeNote);
    }
    return _scrub(out.toString().trimRight());
  }
}

/// The page script threw: a fault in what was asked, not a navigation to wait
/// out, so it is not retried.
class _ScriptError implements Exception {
  const _ScriptError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// [url] with a scheme put in front where it names none: `http://` for this
/// machine, whose dev servers rarely have a certificate, else `https://`.
/// Not `Uri.hasScheme`, which reads `localhost:8080` as the scheme
/// `localhost`.
String pageAddress(String url) {
  if (RegExp(r"^([a-z][a-z0-9+.-]*://|about:|data:)", caseSensitive: false)
      .hasMatch(url)) {
    return url;
  }
  final local = RegExp(r"^(localhost|127(\.\d+){3}|0\.0\.0\.0|\[::1\])(:|/|$)")
      .hasMatch(url);
  return "${local ? "http" : "https"}://$url";
}

/// Whether a page is a human check standing in front of the one asked for.
bool looksLikeChallenge(String title, String text, List<String> frames) {
  const hosts = [
    "challenges.cloudflare.com",
    "google.com/recaptcha",
    "recaptcha.net",
    "hcaptcha.com",
    "arkoselabs.com",
  ];
  if (frames.any((src) => hosts.any(src.contains))) return true;
  return RegExp(
          r"just a moment|verify you are human|are you a robot|"
          r"unusual traffic|captcha|security check|checking your browser",
          caseSensitive: false)
      .hasMatch("$title\n${text.length > 2000 ? text.substring(0, 2000) : text}");
}

const challengeNote = "This looks like a human-verification check. Its "
    "widget is usually a frame listed above, which has no numbered elements "
    "of its own: where you can take a screenshot, do, then click or drag "
    "where it shows by x and y, checking with a last_click screenshot that "
    "the click hit it. If it will not pass after a few tries, call "
    "browser_show if the browser is hidden, ask the user to complete it in "
    "the window, then carry on.";
