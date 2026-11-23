import "dart:async";
import "dart:collection";
import "dart:typed_data";

/// A transport that delivers whole messages, in order, reliably — what an
/// RTCDataChannel gives and everything above this line assumes. One message
/// in is one message out; framing larger payloads across messages is the
/// caller's (the resources chunking of phase 2), not a transport's.
abstract interface class ByteChannel {
  /// Complete incoming messages. Closes when the connection does. Exactly one
  /// [ChannelReader] attaches to it, and it buffers until that happens —
  /// anything else drops whatever arrives before the reader is on, which is a
  /// window every layer above would then have to be written around.
  Stream<Uint8List> get incoming;

  Future<void> send(Uint8List bytes);

  Future<void> close();
}

/// The channel closed with nothing more to read. Distinct from a timeout so
/// a peer vanishing mid-exchange reads as what it is.
class ChannelClosedException implements Exception {
  const ChannelClosedException();

  @override
  String toString() => "channel closed";
}

/// Pulls complete messages off a [ByteChannel] one awaited message at a time,
/// nothing dropped between awaits — the single reader subscription lives as
/// long as the reader does, which is what makes buffering unnecessary to
/// think about at the call sites.
class ChannelReader {
  ChannelReader(ByteChannel channel) {
    _subscription = channel.incoming.listen(
      (bytes) {
        final waiting = _waiting;
        if (waiting != null) {
          _waiting = null;
          waiting.complete(bytes);
        } else {
          _buffered.add(bytes);
        }
      },
      onError: (Object error) {
        final waiting = _waiting;
        if (waiting != null) {
          _waiting = null;
          waiting.completeError(error);
        } else {
          _pendingError = error;
        }
      },
      onDone: () {
        final waiting = _waiting;
        if (waiting != null) {
          _waiting = null;
          waiting.completeError(const ChannelClosedException());
        }
        _closed = true;
      },
    );
  }

  final _buffered = Queue<Uint8List>();
  Completer<Uint8List>? _waiting;
  Object? _pendingError;
  bool _closed = false;
  late final StreamSubscription<Uint8List> _subscription;

  /// Next message, or throws [ChannelClosedException] once the channel has
  /// closed and drained. A message that never comes is the caller's timeout
  /// to impose; the handshake imposes its own.
  Future<Uint8List> next() async {
    if (_buffered.isNotEmpty) return _buffered.removeFirst();
    final error = _pendingError;
    if (error != null) {
      _pendingError = null;
      throw error;
    }
    if (_closed) throw const ChannelClosedException();
    final completer = _waiting = Completer<Uint8List>();
    return completer.future;
  }

  Future<void> cancel() => _subscription.cancel();
}
