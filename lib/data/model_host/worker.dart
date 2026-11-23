import "dart:async";
import "dart:isolate";

import "package:entoli_core/model/model_process.dart";

/// A worker in an isolate of this process.
class IsolateWorker implements Worker {
  IsolateWorker._(this._to, this._out);

  final SendPort _to;
  final StreamController<Object?> _out;

  /// Buffered rather than handed the port directly: a `ReceivePort` can only
  /// be listened to once, and the first thing through it is the worker's own
  /// send port. A single-subscription controller keeps whatever arrives
  /// between that and the caller subscribing — which is where a worker that
  /// failed to load its model says so.
  @override
  Stream<Object?> get messages => _out.stream;

  static Future<IsolateWorker> spawn(
    WorkerKind kind,
    List<Object?> argument,
  ) async {
    final port = ReceivePort();
    final out = StreamController<Object?>();
    final ready = Completer<SendPort>();
    port.listen((message) {
      if (message is SendPort && !ready.isCompleted) {
        return ready.complete(message);
      }
      // The worker's last word, once it has freed its models. Closing here
      // rather than in `close` is what keeps this side listening long enough
      // to know the native handles have actually gone.
      if (message case ["closed"]) return port.close();
      out.add(message);
    });
    await Isolate.spawn(kind.entry, (port.sendPort, argument));
    return IsolateWorker._(await ready.future, out);
  }

  @override
  void send(Object? message) => _to.send(message);

  /// The close message and nothing else. `Isolate.kill` was here too, and it
  /// is a control message that pre-empts anything queued — so the worker
  /// never reached the arm that frees its recognizer, its detector or its
  /// voice, and those are native handles rather than Dart objects. Ending the
  /// loop is what releases them; the isolate then exits because its port is
  /// closed.
  @override
  void close() {
    _to.send(["close"]);
    unawaited(_out.close());
  }
}
