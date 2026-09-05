import "dart:async";
import "dart:io";
import "dart:typed_data";

import "package:dbus/dbus.dart";

import "../../domain/remote_control.dart";

/// Seeing and driving the screen through the XDG desktop portals, which work on
/// both Wayland and X11 (through `xdg-desktop-portal`). Screenshots use the
/// `org.freedesktop.portal.Screenshot` portal — a one-shot capture, no
/// PipeWire stream to manage. Input uses the `org.freedesktop.portal.RemoteDesktop`
/// portal, the only portal that offers pointer and keyboard injection.
///
/// The RemoteDesktop portal needs a session and a device selection, both of
/// which prompt the user through the portal dialog the first time. Until that
/// session is granted, `available` is false and the tools are dropped.
class LinuxRemoteControl extends RemoteControl {
  LinuxRemoteControl();

  DBusClient? _bus;
  _RemoteDesktopSession? _session;

  DBusClient get _client {
    return _bus ??= DBusClient.session();
  }

  @override
  bool get available => true;

  @override
  Future<Uint8List> screenshot() async {
    final client = _client;
    final response = await client.callMethod(
      destination: "org.freedesktop.portal.Desktop",
      path: DBusObjectPath("/org/freedesktop/portal/desktop"),
      interface: "org.freedesktop.portal.Screenshot",
      name: "Screenshot",
      values: [
        const DBusString(""),
        DBusDict.stringVariant({
          "interactive": const DBusBoolean(false),
        }),
      ],
    );
    final handle = response.values.single.asObjectPath();

    final result = await _awaitResponse(
      client,
      handle,
      interface: "org.freedesktop.portal.Screenshot",
    );
    final uri = result["uri"];
    if (uri == null) {
      throw StateError("The screenshot portal returned no image.");
    }
    final path = Uri.parse(uri.asString()).toFilePath();
    final bytes = await _readFile(path);
    if (bytes == null) {
      throw StateError("The screenshot could not be read from $path.");
    }
    return bytes;
  }

  @override
  Future<void> click(int x, int y, {required int button}) async {
    final session = await _ensureSession();
    await session.pointerButtonAbsolute(x, y, button);
  }

  @override
  Future<void> key(String text) async {
    final session = await _ensureSession();
    for (final rune in text.runes) {
      final keycode = _keycodeFor(rune);
      if (keycode == null) continue;
      await session.keyboardKeycode(keycode);
    }
  }

  Future<_RemoteDesktopSession> _ensureSession() async {
    final existing = _session;
    if (existing != null) return existing;
    final session = await _RemoteDesktopSession.start(_client);
    _session = session;
    return session;
  }

  @override
  void close() {
    _bus?.close();
    _bus = null;
    _session = null;
  }

  /// Wait for the portal's `Response` signal for [handle], returning the
  /// results dict. The portal answers asynchronously on a signal rather than in
  /// the method reply.
  Future<Map<String, DBusValue>> _awaitResponse(
    DBusClient client,
    DBusObjectPath handle, {
    required String interface,
  }) async {
    final completer = Completer<Map<String, DBusValue>>();
    final stream = DBusSignalStream(
      client,
      sender: "org.freedesktop.portal.Desktop",
      interface: "org.freedesktop.portal.Request",
      name: "Response",
      path: handle,
    );
    final sub = stream.listen((signal) {
      final values = signal.values;
      if (values.length < 2) return;
      final results = values[1];
      if (results is! DBusDict) return;
      if (!completer.isCompleted) {
        completer.complete(results.mapStringVariant());
      }
    });
    try {
      return await completer.future.timeout(const Duration(seconds: 30));
    } finally {
      await sub.cancel();
    }
  }

  Future<Uint8List?> _readFile(String path) async {
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }
}

/// A RemoteDesktop portal session, held for the life of the app so the user is
/// prompted once rather than per click. The portal grants input injection only
/// after `SelectDevices` and `Start` have been answered.
class _RemoteDesktopSession {
  _RemoteDesktopSession(this._client, this._handle);

  final DBusClient _client;
  final DBusObjectPath _handle;

  static Future<_RemoteDesktopSession> start(DBusClient client) async {
    final response = await client.callMethod(
      destination: "org.freedesktop.portal.Desktop",
      path: DBusObjectPath("/org/freedesktop/portal/desktop"),
      interface: "org.freedesktop.portal.RemoteDesktop",
      name: "CreateSession",
      values: [
        DBusDict.stringVariant({
          "handle_token": const DBusString("entoli"),
        }),
      ],
    );
    final handle = response.values.single.asObjectPath();

    await client.callMethod(
      destination: "org.freedesktop.portal.Desktop",
      path: DBusObjectPath("/org/freedesktop/portal/desktop"),
      interface: "org.freedesktop.portal.RemoteDesktop",
      name: "SelectDevices",
      values: [
        handle,
        DBusDict.stringVariant({
          "types": const DBusUint32(1 | 2), // keyboard | pointer
        }),
      ],
    );

    await client.callMethod(
      destination: "org.freedesktop.portal.Desktop",
      path: DBusObjectPath("/org/freedesktop/portal/desktop"),
      interface: "org.freedesktop.portal.RemoteDesktop",
      name: "Start",
      values: [
        handle,
        const DBusString(""),
        DBusDict.stringVariant({}),
      ],
    );

    return _RemoteDesktopSession(client, handle);
  }

  Future<void> pointerButtonAbsolute(int x, int y, int button) async {
    await _client.callMethod(
      destination: "org.freedesktop.portal.Desktop",
      path: DBusObjectPath("/org/freedesktop/portal/desktop"),
      interface: "org.freedesktop.portal.RemoteDesktop",
      name: "NotifyPointerButtonAbsolute",
      values: [
        _handle,
        DBusDict.stringVariant({
          "stream": const DBusUint32(0),
          "button": DBusUint32(button),
          "state": const DBusUint32(1),
          "x": DBusDouble(x.toDouble()),
          "y": DBusDouble(y.toDouble()),
        }),
      ],
    );
    await _client.callMethod(
      destination: "org.freedesktop.portal.Desktop",
      path: DBusObjectPath("/org/freedesktop/portal/desktop"),
      interface: "org.freedesktop.portal.RemoteDesktop",
      name: "NotifyPointerButtonAbsolute",
      values: [
        _handle,
        DBusDict.stringVariant({
          "stream": const DBusUint32(0),
          "button": DBusUint32(button),
          "state": const DBusUint32(0),
          "x": DBusDouble(x.toDouble()),
          "y": DBusDouble(y.toDouble()),
        }),
      ],
    );
  }

  Future<void> keyboardKeycode(int keycode) async {
    await _client.callMethod(
      destination: "org.freedesktop.portal.Desktop",
      path: DBusObjectPath("/org/freedesktop/portal/desktop"),
      interface: "org.freedesktop.portal.RemoteDesktop",
      name: "NotifyKeyboardKeycode",
      values: [
        _handle,
        DBusDict.stringVariant({
          "stream": const DBusUint32(0),
          "keycode": DBusInt32(keycode),
          "state": const DBusUint32(1),
        }),
      ],
    );
    await _client.callMethod(
      destination: "org.freedesktop.portal.Desktop",
      path: DBusObjectPath("/org/freedesktop/portal/desktop"),
      interface: "org.freedesktop.portal.RemoteDesktop",
      name: "NotifyKeyboardKeycode",
      values: [
        _handle,
        DBusDict.stringVariant({
          "stream": const DBusUint32(0),
          "keycode": DBusInt32(keycode),
          "state": const DBusUint32(0),
        }),
      ],
    );
  }
}

/// The evdev keycode for a rune the portal can type without a modifier, or
/// null where there is no such mapping. The RemoteDesktop portal's
/// `NotifyKeyboardKeycode` carries no shift state, so only the unshifted
/// characters are reachable: lowercase letters, digits, space, enter, tab and
/// backspace. A rune that needs a modifier is skipped rather than guessed at.
int? _keycodeFor(int rune) {
  if (rune >= 0x61 && rune <= 0x7a) return rune - 0x61 + 30; // a-z
  if (rune >= 0x30 && rune <= 0x39) return rune - 0x30 + 11; // 0-9
  if (rune == 0x20) return 57; // space
  if (rune == 0x0a) return 28; // enter
  if (rune == 0x09) return 15; // tab
  if (rune == 0x08) return 14; // backspace
  return null;
}
