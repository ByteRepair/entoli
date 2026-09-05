import "dart:typed_data";

/// Seeing and driving the machine's screen: a screenshot, a click, a key. Like
/// [Shell] and [WebSearch], the platform answers it — a real implementation on
/// Linux and Android, nothing in a browser. The agent's `screenshot`, `click`
/// and `key` tools reach it, and it is offered only while the feature is on and
/// the platform has something behind it.
abstract class RemoteControl {
  const RemoteControl();

  /// Capture the screen as a PNG. Throws where the capture cannot be made, so
  /// the agent words the failure rather than the turn dying.
  Future<Uint8List> screenshot();

  /// A click at [x], [y]. [button] is 1 for primary, 2 for secondary, 3 for
  /// tertiary. Throws where the click cannot be delivered.
  Future<void> click(int x, int y, {required int button});

  /// Send [text] as keyboard input. A single key is text of length one, so one
  /// method covers both a key and a string.
  Future<void> key(String text);

  /// Whether there is anything to reach at all. False on the web, where a
  /// browser cannot see or drive the screen — the tools are dropped the way
  /// `bash` is when there is no shell. A platform fact, like
  /// `WebSearch.available`, not a runtime check: on Android the tools are
  /// offered even while the accessibility service is not connected, and a call
  /// then fails with a clear error rather than being dropped.
  bool get available => true;

  /// Release any resources. The default is a no-op.
  void close() {}
}

/// The web platform's remote control: there isn't one. A browser cannot see or
/// drive the screen, so a call that reaches it anyway is reported as failed
/// rather than thrown.
class UnavailableRemoteControl extends RemoteControl {
  const UnavailableRemoteControl();

  @override
  bool get available => false;

  @override
  Future<Uint8List> screenshot() async =>
      throw UnsupportedError("Remote control is not available in a browser.");

  @override
  Future<void> click(int x, int y, {required int button}) async =>
      throw UnsupportedError("Remote control is not available in a browser.");

  @override
  Future<void> key(String text) async =>
      throw UnsupportedError("Remote control is not available in a browser.");
}
