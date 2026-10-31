import "dart:async";

import "package:flutter/services.dart";

import "host_connection.dart";
import "host_frame.dart";
import "worker.dart";

/// Where the on-device models run. The engines ask this for what they talk
/// to — a [ModelChannel] for the native half, a [Worker] for an isolate — and
/// never learn which process answers. See "The model host" in
/// macos/AGENTS.md.
///
/// macOS runs them in a second process ([HelperModelHost]) because MLX's GPU
/// work in the process that draws the window starves the window's frames:
/// the GPU interleaves processes, not the queues of one. Everywhere else they
/// run here ([InProcessModelHost]) — iOS cannot start a process, and the
/// other platforms' models are a server of their own or run on the CPU.
abstract interface class ModelHost {
  ModelChannel channel(String name);

  Future<Worker> spawn(WorkerKind kind, List<Object?> argument);

  /// Each time the models' process went, and every model loaded in it with
  /// it.
  Stream<void> get lost;
}

/// A method channel's two directions, wherever its native half is: calls out,
/// and what the native half says unasked as [calls]. A failed call throws the
/// [PlatformException] a channel in this process would.
abstract interface class ModelChannel {
  Future<T?> invokeMethod<T>(String method, [Object? arguments]);

  /// Broadcast. An error here is the native half gone ([ModelHostGone]).
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

/// The models in this process.
class InProcessModelHost implements ModelHost {
  const InProcessModelHost();

  @override
  ModelChannel channel(String name) =>
      PlatformModelChannel(MethodChannel(name));

  @override
  Future<Worker> spawn(WorkerKind kind, List<Object?> argument) =>
      IsolateWorker.spawn(kind, argument);

  @override
  Stream<void> get lost => const Stream.empty();
}

/// The models in a second process, started on first use and again after it
/// goes. [_launch] starts one and answers its connection; see
/// `HelperProcess.launch`.
class HelperModelHost implements ModelHost {
  HelperModelHost(this._launch);

  final Future<HostConnection> Function() _launch;

  Future<HostConnection>? _connection;
  final _channels = <String, _RemoteChannel>{};
  final _workers = <int, _RemoteWorker>{};
  final _lost = StreamController<void>.broadcast();
  var _nextWorker = 0;

  Future<HostConnection> _connect() => _connection ??= _start();

  Future<HostConnection> _start() async {
    try {
      final connection = await _launch();
      connection.frames.listen(_route);
      unawaited(connection.done.then((_) => _gone()));
      return connection;
    } catch (_) {
      // The next ask tries again rather than meeting this failure forever.
      _connection = null;
      rethrow;
    }
  }

  void _route(HostFrame frame) => switch (frame) {
    EventFrame(:final channel) => _channels[channel]?._said(frame.call),
    PostFrame(:final worker, :final message) => _workers[worker]?._said(
      message,
    ),
    CloseFrame(:final worker, :final error) =>
      _workers
          .remove(worker)
          ?._ended(error == null ? null : WorkerFailed(error)),
    _ => null,
  };

  void _gone() {
    _connection = null;
    for (final worker in _workers.values) {
      worker._ended(const ModelHostGone());
    }
    _workers.clear();
    for (final channel in _channels.values) {
      channel._gone();
    }
    _lost.add(null);
  }

  @override
  ModelChannel channel(String name) =>
      _channels[name] ??= _RemoteChannel(this, name);

  @override
  Future<Worker> spawn(WorkerKind kind, List<Object?> argument) async {
    final connection = await _connect();
    final id = _nextWorker++;
    final worker = _workers[id] = _RemoteWorker(
      connection,
      id,
      onClose: () => _workers.remove(id),
    );
    connection.send(SpawnFrame(id, kind.name, argument));
    return worker;
  }

  @override
  Stream<void> get lost => _lost.stream;
}

class _RemoteChannel implements ModelChannel {
  _RemoteChannel(this._host, this._name);

  final HelperModelHost _host;
  final String _name;
  final _calls = StreamController<MethodCall>.broadcast();

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    final connection = await _host._connect();
    return await connection.call(_name, method, arguments) as T?;
  }

  @override
  Stream<MethodCall> get calls => _calls.stream;

  void _said(MethodCall call) => _calls.add(call);

  /// Whatever was waiting on the native half is told it went, rather than
  /// left waiting for a frame that will never come.
  void _gone() => _calls.addError(const ModelHostGone());
}

class _RemoteWorker implements Worker {
  _RemoteWorker(this._connection, this._id, {required this.onClose});

  final HostConnection _connection;
  final int _id;
  final void Function() onClose;
  final _out = StreamController<Object?>();

  @override
  Stream<Object?> get messages => _out.stream;

  @override
  void send(Object? message) => _connection.send(PostFrame(_id, message));

  @override
  void close() {
    _connection.send(CloseFrame(_id));
    onClose();
    _ended();
  }

  void _said(Object? message) {
    if (!_out.isClosed) _out.add(message);
  }

  /// Ended by the host rather than in the worker's own words: [error] is
  /// why — its process went ([ModelHostGone]) or it never started
  /// ([WorkerFailed]) — and the host has no business speaking the worker's
  /// vocabulary to say so.
  void _ended([Object? error]) {
    if (_out.isClosed) return;
    if (error != null) _out.addError(error);
    unawaited(_out.close());
  }
}
