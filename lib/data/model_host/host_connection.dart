import "dart:async";
import "dart:io";

import "package:flutter/services.dart";

import "../../core/log.dart";
import "host_frame.dart";

/// One end of the socket between the app and its model host, the same class
/// at both ends. Calls are matched to their answers here; every other frame
/// is [frames]' to route.
class HostConnection {
  HostConnection(this._socket) {
    _socket
        .cast<Uint8List>()
        .transform(const FrameCodec().decoder)
        .listen(_receive, onError: _lost, onDone: () => _lost(null));
  }

  final Socket _socket;
  final _frames = StreamController<HostFrame>.broadcast();
  final _pending = <int, Completer<Object?>>{};
  final _done = Completer<void>();
  var _nextId = 0;

  /// Every frame that is not an answer to [call].
  Stream<HostFrame> get frames => _frames.stream;

  /// Completes when the other end has gone, however it went.
  Future<void> get done => _done.future;

  bool get isOpen => !_done.isCompleted;

  void send(HostFrame frame) {
    if (!isOpen) return;
    for (final part in const FrameCodec().encode(frame)) {
      _socket.add(part);
    }
  }

  /// [method] on the other end's [channel], answered the way a channel in
  /// this process would answer: its result, or the [PlatformException] it
  /// threw.
  Future<Object?> call(String channel, String method, Object? arguments) {
    if (!isOpen) return Future.error(const ModelProcessGone());
    final id = _nextId++;
    final answer = _pending[id] = Completer<Object?>();
    send(CallFrame(id, channel, method, arguments));
    return answer.future;
  }

  void _receive(HostFrame frame) => switch (frame) {
    ReplyFrame(:final id, :final result) =>
      _pending.remove(id)?.complete(result),
    FailFrame(:final id, :final code, :final message) =>
      _pending
          .remove(id)
          ?.completeError(PlatformException(code: code, message: message)),
    _ => _frames.add(frame),
  };

  void _lost(Object? error) {
    if (_done.isCompleted) return;
    if (error != null) logFailure("model-host", "connection failed", error);
    _done.complete();
    for (final answer in _pending.values) {
      answer.completeError(const ModelProcessGone());
    }
    _pending.clear();
    unawaited(_frames.close());
    _socket.destroy();
  }

  void close() => _lost(null);
}

/// The model host went while something was still waiting on it: a crash, a
/// kill, or the app quitting under it.
class ModelProcessGone implements Exception {
  const ModelProcessGone();

  @override
  String toString() => "The on-device model process stopped.";
}
