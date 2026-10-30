import "dart:async";
import "dart:isolate";

/// A worker running a model: messages in, messages out, [close] to stop it.
/// Messages are lists led by a tag — `["speak", generation, text]` — because
/// a list crosses an isolate port and a process boundary alike, where a
/// record crosses only the first.
abstract interface class Worker {
  /// What the worker said, in order, from the first word on.
  Stream<Object?> get messages;

  void send(Object? message);

  /// Asks the worker to free its models and stop.
  void close();
}

/// A worker's entry point, by a name the model host can be asked for: a
/// function cannot cross a process, a name can. [entry] is a top-level
/// function, which `Isolate.spawn` requires.
class WorkerKind {
  const WorkerKind(this.name, this.entry);

  final String name;

  /// Sends its own port first, then answers messages until `["close"]`, and
  /// says `["closed"]` once its native handles are freed.
  final void Function((SendPort, List<Object?>)) entry;
}

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
