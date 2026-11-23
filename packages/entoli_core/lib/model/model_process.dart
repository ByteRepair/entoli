import "dart:async";
import "dart:isolate" show SendPort;

import "package:flutter/services.dart";

/// Where the on-device models run. The engines ask this for what they talk
/// to — a [ModelChannel] for the native half, a [Worker] for an isolate — and
/// never learn which process answers. The app binds it: in this process, or
/// on macOS in a model host of its own. See "The model host" in
/// macos/AGENTS.md.
abstract interface class ModelProcess {
  ModelChannel channel(String name);

  Future<Worker> spawn(WorkerKind kind, List<Object?> argument);

  /// The memory the models' process takes, where they have one of their own
  /// and it is running; null where they share the app's, or nothing has
  /// started it. Never starts one to answer.
  Future<int?> footprint();

  /// Keeps the models' process for as long as the lease is held: a loaded
  /// model holds one, and so does every worker [spawn] makes. With none held
  /// a process of their own has no reason to run, and goes; the next ask
  /// starts another.
  ModelProcessLease hold();
}

/// One reason for the models' process to keep running, given up once —
/// by its holder, or by the process going while it was held.
class ModelProcessLease {
  ModelProcessLease(this._release);

  void Function()? _release;
  final _lost = Completer<void>();

  /// Completes if the process went while this was held, and everything the
  /// holder had in it with it. The lease is given up by then: the next
  /// process owes this holder nothing.
  Future<void> get lost => _lost.future;

  /// Whether [lost] has completed: the process, and what was in it, gone.
  bool get isLost => _lost.isCompleted;

  void release() {
    final release = _release;
    _release = null;
    release?.call();
  }

  /// The process going, said by the [ModelProcess] that granted it.
  /// Not a release: the process that would have gone idle has gone already,
  /// and its holds with it.
  void lose() {
    if (_release == null) return;
    _release = null;
    _lost.complete();
  }
}

/// A method channel's two directions, wherever its native half is: calls out,
/// and what the native half says unasked as [calls]. A failed call throws the
/// [PlatformException] a channel in this process would.
abstract interface class ModelChannel {
  Future<T?> invokeMethod<T>(String method, [Object? arguments]);

  /// Broadcast. An error here is the native half gone ([ModelProcessGone]).
  Stream<MethodCall> get calls;
}

/// A channel whose native half is in this process. One per name for the
/// process's life: a method channel takes one handler, so a second
/// registration would land on the first's — this owns it and broadcasts.
class PlatformModelChannel implements ModelChannel {
  factory PlatformModelChannel(MethodChannel channel) =>
      _channels[channel.name] ??= PlatformModelChannel._(channel);

  PlatformModelChannel._(this._channel) {
    _channel.setMethodCallHandler((call) async => _calls.add(call));
  }

  static final _channels = <String, PlatformModelChannel>{};

  final MethodChannel _channel;
  final _calls = StreamController<MethodCall>.broadcast();

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) =>
      _channel.invokeMethod<T>(method, arguments);

  @override
  Stream<MethodCall> get calls => _calls.stream;
}

/// A worker running a model: messages in, messages out, [close] to stop it.
/// Messages are lists led by a tag — `["speak", generation, text]` — because
/// a list crosses an isolate port and a process boundary alike, where a
/// record crosses only the first.
abstract interface class Worker {
  /// What the worker said, in order, from the first word on. An error here is
  /// the worker ended under it rather than in its own words — the model
  /// host's process gone ([ModelProcessGone]), or the worker never started
  /// there ([WorkerFailed]) — and the stream closes after it. In this process
  /// neither reaches here: there is no second process to lose, and a worker
  /// that cannot start fails its `spawn`.
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

/// A worker the model host could not start, with the host's reason: the
/// remote counterpart of a `spawn` in this process that threw.
class WorkerFailed implements Exception {
  const WorkerFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The model host went while something was still waiting on it: a crash, a
/// kill, or the app quitting under it.
class ModelProcessGone implements Exception {
  const ModelProcessGone();

  @override
  String toString() => "The on-device model process stopped.";
}
