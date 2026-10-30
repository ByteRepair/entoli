import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:flutter/services.dart" show MethodChannel, PlatformException;

import "../../core/log.dart";
import "cdp.dart";

/// iOS's browser, behind the slice of the DevTools Protocol `CdpBrowser`'s
/// tab sends, so the tab is the one the desktops and Android run. Each chat's
/// page is a WKWebView made by `BrowserChannel.swift`; WebKit serves no
/// protocol an app can reach, so a script is `evaluateJavaScript`, a picture
/// `takeSnapshot`, and input is DOM events made in the page — which the page
/// sees as untrusted, and which cannot reach into a cross-site frame. See
/// "On iOS" under "The browser" in `lib/data/builtin/AGENTS.md`.
class WebKitConnection implements CdpConnection {
  WebKitConnection(this._channel) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == "event") {
        _event((call.arguments as Map).cast<String, Object?>());
      }
    });
  }

  final MethodChannel _channel;
  final _events = StreamController<CdpEvent>.broadcast();
  final _closed = Completer<void>();

  /// The screencast's wait for each frame's ack, per chat casting.
  final _acks = <String, Completer<void>?>{};

  /// The page script's world, which is one per page and kept across
  /// navigations: a named `WKContentWorld`.
  static const _world = 1;

  @override
  Stream<CdpEvent> get events => _events.stream;

  @override
  Future<void> get done => _closed.future;

  @override
  bool get isClosed => _closed.isCompleted;

  @override
  Future<Map<String, dynamic>> send(
    String method, {
    Map<String, dynamic> params = const {},
    String? sessionId,
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (isClosed) {
      return Future.error(const CdpException("The browser has closed."));
    }
    return _send(method, params, sessionId ?? "").timeout(
      timeout,
      onTimeout: () =>
          throw CdpException("$method took longer than ${timeout.inSeconds}s."),
    );
  }

  Future<Map<String, dynamic>> _send(
    String method,
    Map<String, dynamic> params,
    String chat,
  ) async {
    try {
      switch (method) {
        case "Page.enable":
          return const {};
        case "Target.attachToTarget":
          return {"sessionId": params["targetId"]};
        case "Page.createIsolatedWorld":
          return {"executionContextId": _world};
        case "Target.getTargets":
          final pages =
              await _channel.invokeListMethod<Map>("targets") ?? const [];
          return {
            "targetInfos": [
              for (final page in pages) ...[
                // The address the tab finds its page by; the page's own is
                // what the page script reads.
                {
                  "targetId": page["chat"],
                  "type": "page",
                  "url": "about:blank?entoli=${page["chat"]}",
                },
                for (final url in page["frames"] as List)
                  {"type": "iframe", "parentFrameId": page["chat"], "url": url},
              ],
            ],
          };
        case "Runtime.evaluate":
          try {
            return {
              "result": {
                "value": await _eval(
                  chat,
                  params["expression"] as String,
                  isolated: params["contextId"] == _world,
                ),
              },
            };
          } on PlatformException catch (e) {
            if (e.code != "exception") rethrow;
            return {
              "exceptionDetails": {"text": e.message},
            };
          }
        case "Page.navigate":
          return {
            "errorText": await _call("navigate", chat, {"url": params["url"]}),
          };
        case "Page.getNavigationHistory":
          final history = await _call("history", chat) as Map;
          return {
            "currentIndex": history["current"],
            "entries": [
              for (final (i, url) in (history["urls"] as List).indexed)
                {"id": i, "url": url},
            ],
          };
        case "Page.navigateToHistoryEntry":
          await _call("go", chat, {"index": params["entryId"]});
          return const {};
        case "Page.reload":
          await _call("reload", chat);
          return const {};
        case "Page.getLayoutMetrics":
          final [x, y, width, height] = await _viewport(chat);
          return {
            "cssVisualViewport": {
              "pageX": x,
              "pageY": y,
              "clientWidth": width,
              "clientHeight": height,
            },
          };
        case "Page.captureScreenshot":
          // The clip is in the document; a snapshot is of the viewport.
          final clip = params["clip"] as Map;
          final [x as num, y as num, _, _] = await _viewport(chat);
          final png =
              await _call("snapshot", chat, {
                    "x": (clip["x"] as num) - x,
                    "y": (clip["y"] as num) - y,
                    "width": clip["width"],
                    "height": clip["height"],
                  })
                  as Uint8List;
          return {"data": base64Encode(png)};
        case "Page.startScreencast":
          unawaited(_cast(chat));
          return const {};
        case "Page.screencastFrameAck":
          _acks[chat]?.complete();
          return const {};
        case "Page.stopScreencast":
          _acks.remove(chat)?.complete();
          return const {};
        case "Input.dispatchMouseEvent":
          await _eval(chat, "($_mouse)(${jsonEncode(params)})", isolated: true);
          return const {};
        case "Input.dispatchKeyEvent":
          await _eval(chat, "($_key)(${jsonEncode(params)})", isolated: true);
          return const {};
        case "Input.insertText":
          await _eval(
            chat,
            "document.execCommand('insertText', false, ${jsonEncode(params["text"])})",
            isolated: true,
          );
          return const {};
        default:
          throw CdpException("$method is not available on iOS.");
      }
    } on PlatformException catch (e) {
      throw CdpException(e.message ?? e.code);
    }
  }

  Future<Object?> _call(
    String method,
    String chat, [
    Map<String, Object?> args = const {},
  ]) => _channel.invokeMethod(method, {"chat": chat, ...args});

  Future<Object?> _eval(String chat, String js, {required bool isolated}) =>
      _call("eval", chat, {"js": js, "isolated": isolated});

  Future<List<Object?>> _viewport(String chat) async =>
      await _eval(
            chat,
            "[visualViewport.pageLeft, visualViewport.pageTop, "
            "visualViewport.width, visualViewport.height]",
            isolated: true,
          )
          as List<Object?>;

  /// Chrome sends a frame on each repaint; WebKit has no such stream, so the
  /// page is snapshotted a few times a second, each frame waiting on the ack
  /// of the one before, as Chrome's do.
  Future<void> _cast(String chat) async {
    if (_acks.containsKey(chat)) return;
    _acks[chat] = null;
    for (var n = 1; _acks.containsKey(chat) && !isClosed; n++) {
      try {
        final [_, _, width, height] = await _viewport(chat);
        final jpeg =
            await _call("snapshot", chat, {
                  "x": 0,
                  "y": 0,
                  "width": width,
                  "height": height,
                  "jpeg": true,
                })
                as Uint8List;
        if (!_acks.containsKey(chat) || isClosed) return;
        final ack = _acks[chat] = Completer<void>();
        _events.add(
          CdpEvent("Page.screencastFrame", {
            "data": base64Encode(jpeg),
            "sessionId": n,
            "metadata": {"deviceWidth": width, "deviceHeight": height},
          }, chat),
        );
        await ack.future;
      } catch (e) {
        logFailure("browser", "the screencast of $chat stopped", e);
        _acks.remove(chat);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  void _event(Map<String, Object?> event) {
    if (isClosed) return;
    final chat = event["chat"] as String;
    final (method, params) = switch (event["type"]) {
      "started" => ("Page.frameStartedLoading", {"frameId": chat}),
      "loaded" => ("Page.loadEventFired", const <String, Object?>{}),
      "navigated" => (
        "Page.frameNavigated",
        {
          "frame": {"id": chat, "url": event["url"]},
        },
      ),
      "closed" => ("Target.targetDestroyed", {"targetId": chat}),
      _ => (null, null),
    };
    if (method == null) return;
    _events.add(
      CdpEvent(
        method,
        params!.cast<String, dynamic>(),
        method == "Target.targetDestroyed" ? null : chat,
      ),
    );
  }

  @override
  Future<void> close() async {
    if (isClosed) return;
    _closed.complete();
    for (final ack in _acks.values) {
      ack?.complete();
    }
    _acks.clear();
    await _events.close();
  }
}

/// A mouse event as the protocol names one, made into the DOM's. Run in the
/// page script's world, whose `window` the page cannot see, so what it keeps
/// between calls — the element under the pointer — is its own.
const _mouse = r"""e => {
  const at = document.elementFromPoint(e.x, e.y) || document.documentElement;
  const init = {
    bubbles: true, cancelable: true, composed: true, view: window,
    clientX: e.x, clientY: e.y, detail: e.clickCount || 0,
    button: e.button === 'right' ? 2 : e.button === 'middle' ? 1 : 0,
    buttons: e.buttons || 0,
    altKey: !!(e.modifiers & 1), ctrlKey: !!(e.modifiers & 2),
    metaKey: !!(e.modifiers & 4), shiftKey: !!(e.modifiers & 8),
    pointerId: 1, pointerType: 'mouse', isPrimary: true,
  };
  const fire = (Type, name, on = at) => on.dispatchEvent(new Type(name, init));
  if (e.type === 'mouseMoved') {
    const was = window.__entoliOver;
    if (was !== at) {
      if (was && was.isConnected) {
        for (const n of ['pointerout', 'pointerleave']) fire(PointerEvent, n, was);
        for (const n of ['mouseout', 'mouseleave']) fire(MouseEvent, n, was);
      }
      for (const n of ['pointerover', 'pointerenter']) fire(PointerEvent, n);
      for (const n of ['mouseover', 'mouseenter']) fire(MouseEvent, n);
      window.__entoliOver = at;
    }
    fire(PointerEvent, 'pointermove');
    fire(MouseEvent, 'mousemove');
  } else if (e.type === 'mousePressed') {
    fire(PointerEvent, 'pointerdown');
    if (fire(MouseEvent, 'mousedown')) {
      const focusable = at.closest('input, textarea, select, button, a[href], [tabindex], [contenteditable]:not([contenteditable="false"])');
      if (focusable) focusable.focus();
      else document.activeElement?.blur?.();
    }
  } else if (e.type === 'mouseReleased') {
    fire(PointerEvent, 'pointerup');
    fire(MouseEvent, 'mouseup');
    if (init.button === 2) fire(MouseEvent, 'contextmenu');
    else {
      fire(MouseEvent, 'click');
      if (e.clickCount === 2) fire(MouseEvent, 'dblclick');
    }
  } else if (e.type === 'mouseWheel') {
    const wheel = new WheelEvent('wheel', {...init, deltaX: e.deltaX || 0, deltaY: e.deltaY || 0});
    if (!at.dispatchEvent(wheel)) return null;
    // The innermost scroller under the point takes it, as a wheel's would.
    for (let el = at; el && el !== document.documentElement; el = el.parentElement) {
      const s = getComputedStyle(el);
      const y = /auto|scroll/.test(s.overflowY) && el.scrollHeight > el.clientHeight;
      const x = /auto|scroll/.test(s.overflowX) && el.scrollWidth > el.clientWidth;
      if ((e.deltaY && y) || (e.deltaX && x)) {
        el.scrollBy(e.deltaX || 0, e.deltaY || 0);
        return null;
      }
    }
    window.scrollBy(e.deltaX || 0, e.deltaY || 0);
  }
  return null;
}""";

/// A key as the protocol names one. A made key event inserts nothing, so
/// what the key would have done is done after it, unless the page cancelled
/// it: text inserted, Enter a line or a submit, Backspace and Delete.
const _key = r"""e => {
  const t = document.activeElement || document.body;
  const init = {
    key: e.key, code: e.code, keyCode: e.windowsVirtualKeyCode,
    which: e.windowsVirtualKeyCode, bubbles: true, cancelable: true, composed: true,
    altKey: !!(e.modifiers & 1), ctrlKey: !!(e.modifiers & 2),
    metaKey: !!(e.modifiers & 4), shiftKey: !!(e.modifiers & 8),
  };
  if (e.type === 'keyUp') {
    t.dispatchEvent(new KeyboardEvent('keyup', init));
    return null;
  }
  if (!t.dispatchEvent(new KeyboardEvent('keydown', init))) return null;
  if (e.commands) {
    for (const c of e.commands) document.execCommand(c);
    return null;
  }
  if (e.text != null) {
    const code = e.text.charCodeAt(0);
    if (!t.dispatchEvent(new KeyboardEvent('keypress', {...init, charCode: code, keyCode: code, which: code}))) return null;
    if (e.text !== '\r') document.execCommand('insertText', false, e.text);
    else if (t.tagName === 'TEXTAREA') document.execCommand('insertText', false, '\n');
    else if (t.isContentEditable) document.execCommand('insertParagraph');
    else if (t.form) t.form.requestSubmit();
  } else if (e.key === 'Backspace') document.execCommand('delete');
  else if (e.key === 'Delete') document.execCommand('forwardDelete');
  return null;
}""";
