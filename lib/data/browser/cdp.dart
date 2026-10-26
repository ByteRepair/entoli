import "dart:async";
import "dart:convert";
import "dart:io";

/// One WebSocket to a browser's DevTools endpoint, with every page's session
/// multiplexed over it (`Target.attachToTarget` with `flatten`).
class CdpConnection {
  CdpConnection._(this._socket) {
    _socket.listen(_receive,
        onDone: _finish, onError: (_) => _finish(), cancelOnError: true);
  }

  static Future<CdpConnection> connect(Uri url, {HttpClient? client}) async =>
      CdpConnection._(await WebSocket.connect(url.toString(), customClient: client)
          .timeout(const Duration(seconds: 15)));

  final WebSocket _socket;
  var _nextId = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<CdpEvent>.broadcast();
  final _closed = Completer<void>();

  Stream<CdpEvent> get events => _events.stream;

  /// Completes when the browser goes away, closed by the user or killed.
  Future<void> get done => _closed.future;

  bool get isClosed => _closed.isCompleted;

  Future<Map<String, dynamic>> send(
    String method, {
    Map<String, dynamic> params = const {},
    String? sessionId,
    Duration timeout = const Duration(seconds: 30),
  }) {
    if (isClosed) {
      return Future.error(const CdpException("The browser has closed."));
    }
    final id = ++_nextId;
    final reply = Completer<Map<String, dynamic>>();
    _pending[id] = reply;
    _socket.add(jsonEncode({
      "id": id,
      "method": method,
      "params": params,
      "sessionId": ?sessionId,
    }));
    return reply.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw CdpException("$method took longer than ${timeout.inSeconds}s.");
    });
  }

  void _receive(dynamic data) {
    // A closing socket still delivers what was in flight.
    if (isClosed) return;
    final Map<String, dynamic> message;
    try {
      message = jsonDecode(data as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = message["id"];
    if (id is int) {
      final reply = _pending.remove(id);
      if (reply == null) return;
      final error = message["error"];
      if (error is Map) {
        reply.completeError(CdpException("${error["message"]}"));
      } else {
        reply.complete(
            (message["result"] as Map?)?.cast<String, dynamic>() ?? const {});
      }
      return;
    }
    final method = message["method"];
    if (method is String) {
      _events.add(CdpEvent(
        method,
        (message["params"] as Map?)?.cast<String, dynamic>() ?? const {},
        message["sessionId"] as String?,
      ));
    }
  }

  void _finish() {
    if (_closed.isCompleted) return;
    _closed.complete();
    for (final reply in _pending.values) {
      reply.completeError(const CdpException("The browser has closed."));
    }
    _pending.clear();
    _events.close();
  }

  Future<void> close() async {
    await _socket.close();
    _finish();
  }
}

class CdpEvent {
  const CdpEvent(this.method, this.params, this.sessionId);

  final String method;
  final Map<String, dynamic> params;
  final String? sessionId;
}

class CdpException implements Exception {
  const CdpException(this.message);

  final String message;

  @override
  String toString() => message;
}
