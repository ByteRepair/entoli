import "dart:async";
import "dart:convert";
import "dart:typed_data";

import "package:cryptography/cryptography.dart";

import "channel.dart";
import "handshake.dart" show Handshake;

/// An encrypted [ByteChannel]: every message on the wire is
///
///     [type: 1 byte][counter: 4 bytes BE][AEAD(cleartext)]
///
/// with ChaCha20-Poly1305, the nonce the counter zero-extended to 96 bits and
/// the type byte as associated data. Counters are per direction and monotonic
/// — a replayed, reordered or spliced frame fails its MAC — and the keys came
/// out of a [Handshake], so nothing readable touches the wire after it.
final class SecureChannel implements ByteChannel {
  SecureChannel._(this._raw, this._sendKey, this._recvKey, this._reader) {
    _cipher = Chacha20.poly1305Aead();
  }

  static const typeControl = 0;
  static const typeBinary = 1;

  final ByteChannel _raw;
  final ChannelReader _reader;
  late final Chacha20 _cipher;
  late final SecretKey _sendKey;
  late final SecretKey _recvKey;

  int _sendCounter = 0;
  int _recvCounter = 0;

  /// The stream this class exposes.
  final _controller = StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get incoming => _controller.stream;

  bool _closed = false;

  /// Runs the handshake over [raw] and returns the channel above it. The raw
  /// channel must not be read or written by anyone else from here on.
  static Future<SecureChannel> open(
    ByteChannel raw, {
    required Handshake handshake,
    required bool initiator,
  }) async {
    final keys = await handshake.run(raw, initiator: initiator);
    return SecureChannel._(
      raw,
      keys.send,
      keys.recv,
      ChannelReader(raw),
    );
  }

  Uint8List _nonce(int counter) {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setUint64(4, counter);
    return nonce;
  }

  Future<Uint8List> _seal(int type, Uint8List payload) async {
    final box = await _cipher.encrypt(
      payload,
      secretKey: _sendKey,
      nonce: _nonce(_sendCounter),
      aad: [type],
    );
    final mac = box.mac.bytes;
    final frame = Uint8List(5 + box.cipherText.length + mac.length);
    frame[0] = type;
    ByteData.sublistView(frame).setUint32(1, _sendCounter);
    frame.setAll(5, box.cipherText);
    frame.setAll(5 + box.cipherText.length, mac);
    _sendCounter++;
    return frame;
  }

  @override
  Future<void> send(Uint8List bytes) =>
      _dispatch(typeControl, bytes);

  /// Binary payloads (resource chunks in phase 2) ride their own type so a
  /// control message can never be mistaken for one.
  Future<void> sendBinary(Uint8List bytes) =>
      _dispatch(typeBinary, bytes);

  Future<void> _dispatch(int type, Uint8List payload) async {
    if (_closed) throw StateError("secure channel closed");
    await _raw.send(await _seal(type, payload));
  }

  /// Starts decrypting incoming frames into [incoming]. Call once; frames
  /// arriving before this are buffered by the transport's reader and drained
  /// here.
  void listen() {
    () async {
      while (!_closed) {
        Uint8List frame;
        try {
          frame = await _reader.next();
        } on ChannelClosedException {
          break;
        } catch (error) {
          if (_closed) break;
          _controller.addError(error);
          break;
        }
        try {
          final plain = await _open(frame);
          if (!_closed) _controller.add(plain);
        } on SecretBoxAuthenticationError {
          _fail(const FrameAuthenticationException());
          return;
        }
      }
      if (!_closed) _controller.close();
    }();
  }

  Future<Uint8List> _open(Uint8List frame) async {
    if (frame.length < 5 + 16) {
      throw const FrameFormatException("frame too short");
    }
    final type = frame[0];
    // `sublistView` rather than `ByteData.view(frame.buffer)`: a frame off a
    // real data channel is a view into a larger receive buffer, and reading
    // through the buffer ignores where the view starts — so the header came
    // out of whatever happened to be in front of it. A loopback channel hands
    // back freshly allocated lists, which is why this only ever showed up
    // over WebRTC.
    final counter = ByteData.sublistView(frame).getUint32(1);
    if (counter != _recvCounter) {
      throw FrameFormatException("counter jumped: $counter != $_recvCounter");
    }
    final cipherText = frame.sublist(5, frame.length - 16);
    final mac = Mac(frame.sublist(frame.length - 16));
    final plain = await _cipher.decrypt(
      SecretBox(cipherText, nonce: _nonce(counter), mac: mac),
      secretKey: _recvKey,
      aad: [type],
    );
    _recvCounter++;
    return Uint8List.fromList(plain);
  }

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    _controller.addError(error);
    _controller.close();
    _raw.close();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _controller.close();
    await _raw.close();
  }
}

class FrameAuthenticationException implements Exception {
  const FrameAuthenticationException();

  @override
  String toString() => "a frame failed authentication";
}

class FrameFormatException implements Exception {
  const FrameFormatException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// JSON helpers over a [SecureChannel]'s control type. Everything the two
/// hubs say to each other goes through here.
extension SecureJson on SecureChannel {
  Future<void> sendJson(Map<String, Object?> json) =>
      send(utf8.encode(jsonEncode(json)));

  Stream<Map<String, dynamic>> get jsonIncoming => incoming.map(
        (bytes) => jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
      );
}
