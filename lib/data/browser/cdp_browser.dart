import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:math";

import "package:path/path.dart" as p;

import "../../core/log.dart";
import "../../domain/agent_browser.dart";
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
    this.idle = const Duration(minutes: 10),
  });

  /// `<cache>/browser`: the download, the profile and the probes under it.
  final String browserDir;

  /// The setting: null off, [embeddedBrowserId], or an executable's path.
  final String? Function() picked;

  @override
  final EmbeddedBrowser embedded;

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

  _Running? _running;
  Future<_Running>? _starting;
  Timer? _idleTimer;
  final _tabs = <String, _CdpTab>{};

  @override
  BrowserTab tab(String chatId) =>
      _tabs.putIfAbsent(chatId, () => _CdpTab(this, chatId));

  /// The running browser, launched if none is or the pick has changed since.
  Future<_Running> _ensure() async {
    _idleTimer?.cancel();
    _idleTimer = Timer(idle, () => unawaited(close()));
    final exe = _executable ??
        (throw const CdpException(
            "No browser is picked, or the picked one is gone: see Settings > "
            "Agent Browser."));
    final running = _running;
    if (running != null && running.executable == exe && !running.cdp.isClosed) {
      return running;
    }
    if (running != null) await close();
    return _starting ??= _launch(exe, _profile).then((started) {
      _running = started;
      unawaited(started.cdp.done.then((_) {
        if (identical(_running, started)) _running = null;
        for (final tab in _tabs.values) {
          tab._forget();
        }
      }));
      return started;
    }).whenComplete(() => _starting = null);
  }

  @override
  Future<void> close() async {
    _idleTimer?.cancel();
    final running = _running;
    _running = null;
    for (final tab in _tabs.values) {
      tab._forget();
    }
    if (running == null) return;
    try {
      await running.cdp.send("Browser.close", timeout: const Duration(seconds: 5));
    } catch (_) {
      // Gone already, or not answering: the kill below covers both.
    }
    await running.cdp.close();
    await running.process.exitCode
        .timeout(const Duration(seconds: 5), onTimeout: () {
      running.process.kill();
      return -1;
    });
  }

  @override
  Future<List<FoundBrowser>> detect() async => [
        for (final (name, path) in _candidates())
          if (await File(path).exists()) FoundBrowser(name, path),
      ];

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
      try {
        await started.cdp.send("Browser.close");
      } catch (_) {}
      await started.cdp.close();
      await started.process.exitCode
          .timeout(const Duration(seconds: 5), onTimeout: () {
        started.process.kill();
        return -1;
      });
      return exe;
    } finally {
      try {
        await Directory(probe).delete(recursive: true);
      } catch (_) {}
    }
  }
}

class _Running {
  _Running(this.executable, this.process, this.cdp);

  final String executable;
  final Process process;
  final CdpConnection cdp;
}

/// The AppImage runtime's variables describe this app, not the browser being
/// launched — Helium's own AppImage would read ours as its own.
const _appImageVars = {"APPIMAGE", "APPDIR", "ARGV0", "OWD"};

/// Start [exe] on [profile] with a DevTools port of its choosing, and connect.
/// The port is read from `DevToolsActivePort`, which the browser writes into
/// the profile once it listens: no port is guessed, so none can be taken.
Future<_Running> _launch(String exe, String profile,
    {bool headless = false}) async {
  await Directory(profile).create(recursive: true);
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
      if (headless) "--headless=new",
      "about:blank",
    ],
    environment: {
      for (final e in Platform.environment.entries)
        if (!_appImageVars.contains(e.key)) e.key: e.value,
    },
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
          return _Running(exe, process, await CdpConnection.connect(url));
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
    ].fold<List<(String, String)>>([], (found, candidate) {
      // One entry per name, the first on PATH: a browser installed as both
      // `google-chrome` and `google-chrome-stable` is one browser.
      if (!found.any((f) => f.$1 == candidate.$1) &&
          File(candidate.$2).existsSync()) {
        found.add(candidate);
      }
      return found;
    });
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
  _CdpTab(this._browser, this.chatId);

  final CdpBrowser _browser;
  final String chatId;

  ({String target, String session})? _page;
  var _pointer = (x: 0.0, y: 0.0);
  final _random = Random();

  void _forget() => _page = null;

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
      page = (target: target, session: session);
      _page = page;
      // The user closing the tab is the tab gone; the next call opens another.
      final sub = cdp.events
          .where((e) =>
              (e.method == "Target.detachedFromTarget" &&
                  e.params["sessionId"] == session) ||
              (e.method == "Target.targetDestroyed" &&
                  e.params["targetId"] == target))
          .listen(null);
      sub.onData((_) {
        if (_page?.session == session) _page = null;
        sub.cancel();
      });
    }
    // In front, or Chrome throttles it and a screenshot of it never comes.
    await cdp.send("Target.activateTarget", params: {"targetId": page.target});
    return (cdp: cdp, target: page.target, session: page.session);
  }

  Future<dynamic> _eval(String expression) async {
    for (var attempt = 0;; attempt++) {
      final page = await _attach();
      try {
        final world = await page.cdp.send("Page.createIsolatedWorld",
            params: {"frameId": page.target, "worldName": "entoli"},
            sessionId: page.session);
        final result = await page.cdp.send("Runtime.evaluate",
            params: {
              "expression": "$pageScript\n$expression",
              "contextId": world["executionContextId"],
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
        // document answers once it is there.
        if (attempt >= 3) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 500));
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

  @override
  Future<String> goto(String url) async {
    final target = Uri.tryParse(url)?.hasScheme == true ? url : "https://$url";
    final page = await _attach();
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
    final history = await page.cdp
        .send("Page.getNavigationHistory", sessionId: page.session);
    final index = history["currentIndex"] as int;
    if (index <= 0) return "There is no earlier page in this tab.\n\n${await _describeView()}";
    final entries = history["entries"] as List;
    await _act(() => page.cdp.send("Page.navigateToHistoryEntry",
        params: {"entryId": (entries[index - 1] as Map)["id"]},
        sessionId: page.session));
    return _describeView();
  }

  @override
  Future<String> click({int? ref, double? x, double? y}) async {
    if (ref != null) {
      final rect = await _rect(ref);
      final width = (rect["width"] as num).toDouble();
      final height = (rect["height"] as num).toDouble();
      // Off the exact centre, the way a pointer lands.
      final cx = (rect["left"] as num) + width * (0.4 + _random.nextDouble() * 0.2);
      final cy = (rect["top"] as num) + height * (0.4 + _random.nextDouble() * 0.2);
      await _act(() => _clickAt(cx.toDouble(), cy.toDouble()));
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
  Future<String> type(int ref, String text, {bool submit = false}) async {
    final chosen = await _eval("window.__entoli.choose($ref, ${jsonEncode(text)})");
    if (chosen == "none") {
      throw CdpException("[$ref] has no option matching \"$text\".");
    }
    if (chosen == null) {
      final rect = await _rect(ref);
      await _clickAt(
          (rect["left"] as num) + (rect["width"] as num) / 2.0,
          (rect["top"] as num) + (rect["height"] as num) / 2.0);
      await _eval("window.__entoli.selectContents($ref)");
      final page = await _attach();
      if (text.isEmpty) {
        await _key(page, "Backspace", 8);
      } else {
        await page.cdp.send("Input.insertText",
            params: {"text": text}, sessionId: page.session);
      }
    }
    if (submit) {
      final page = await _attach();
      await _act(() => _key(page, "Enter", 13, text: "\r"));
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return _describeView();
  }

  Future<void> _key(
      ({CdpConnection cdp, String target, String session}) page,
      String key,
      int code,
      {String? text}) async {
    for (final type in ["keyDown", "keyUp"]) {
      await page.cdp.send("Input.dispatchKeyEvent",
          params: {
            "type": type,
            "key": key,
            "code": key,
            "windowsVirtualKeyCode": code,
            if (type == "keyDown" && text != null) "text": text,
          },
          sessionId: page.session);
    }
  }

  @override
  Future<String> scroll({bool up = false}) async {
    final before = await _snapshot(all: false);
    final page = await _attach();
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
    return out.toString().trimRight();
  }

  @override
  Future<BrowserShot> screenshot({int? ref}) async {
    final Map<String, dynamic> clip;
    double left = 0, top = 0;
    final page = await _attach();
    // The clip's scale multiplies device pixels. Undone, a pixel in the image
    // is a CSS pixel in the viewport, which is what a click takes — on a
    // HiDPI screen it would otherwise be off by the ratio.
    final scale = 1 / ((await _eval("devicePixelRatio") as num?) ?? 1);
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
    final shot = await page.cdp.send("Page.captureScreenshot",
        params: {"format": "png", "clip": clip, "captureBeyondViewport": false},
        sessionId: page.session);
    return BrowserShot(base64Decode(shot["data"] as String), left: left, top: top);
  }

  @override
  Future<String> describeTarget({int? ref, double? x, double? y}) async {
    final what = await _eval("window.__entoli.line(${ref ?? "null"}, "
        "${x ?? 0}, ${y ?? 0})");
    final where = await _eval("location.href");
    final at = ref == null ? " at ($x, $y)" : "";
    return "${what ?? "nothing"}$at on $where";
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

  Future<String> _describeView() async {
    final page = await _snapshot(all: false);
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
    return out.toString().trimRight();
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
    "where it shows by x and y. If it will not pass after a few tries, ask "
    "the user to complete it in the browser window, then carry on.";
