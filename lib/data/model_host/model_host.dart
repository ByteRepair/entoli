import "dart:async";

import "package:flutter/services.dart";

import "host_connection.dart";
import "host_frame.dart";
import "worker.dart";

/// The host process's own native half: `quit`, which it is asked as it
/// leaves, and `footprint`, its memory as the app shows it. Served beside
/// whatever channels the host was given, since every host has one.
const modelHostChannel = MethodChannel("agent_chat/model_host");

/// Where the on-device models run. The engines ask this for what they talk
/// to — a [ModelChannel] for the native half, a [Worker] for an isolate — and
/// never learn which process answers. See "The model host" in
/// macos/AGENTS.md.
///
/// macOS runs them in a second process ([HelperModelProcess]) because MLX's GPU
/// work in the process that draws the window starves the window's frames:
/// the GPU interleaves processes, not the queues of one. Everywhere else they
/// run here ([InAppModelProcess]) — iOS cannot start a process, and the
/// other platforms' models are a server of their own or run on the CPU.
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

  void release() {
    final release = _release;
    _release = null;
    release?.call();
  }

  /// The process going, said by the [ModelProcess] that granted it.
  void lose() {
    if (_release == null) return;
    release();
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

/// The models in this process.
class InAppModelProcess implements ModelProcess {
  const InAppModelProcess();

  @override
  ModelChannel channel(String name) =>
      PlatformModelChannel(MethodChannel(name));

  @override
  Future<Worker> spawn(WorkerKind kind, List<Object?> argument) =>
      IsolateWorker.spawn(kind, argument);

  /// This process runs whatever is held, and goes with the app.
  @override
  ModelProcessLease hold() => ModelProcessLease(() {});

  /// The models are in the app's own process, which is the app's memory and
  /// not theirs to report.
  @override
  Future<int?> footprint() async => null;
}

/// The models in a second process, started on first use and again after it
/// goes, and let go once nothing has held it for [idle]. [_launch] starts one
/// and answers its connection; see `HelperProcess.launch`.
///
/// The wait is for the uses that come back: a voice conversation picked up
/// again, a model unloaded and asked for. Relaunching costs a second, which a
/// model's load hides and a tap on the microphone does not; five idle minutes
/// is the point past which the process is only taking up room.
class HelperModelProcess implements ModelProcess {
  HelperModelProcess(this._launch, {this.idle = const Duration(minutes: 5)});

  final Future<HostConnection> Function() _launch;

  final Duration idle;

  /// Running while nothing holds the process; held again, it is called off.
  Timer? _idleTimer;

  Future<HostConnection>? _connection;

  /// The leases out. The app decides when the process is done rather than
  /// the process itself, since only this side knows a load is about to
  /// arrive.
  final _leases = <ModelProcessLease>{};
  final _channels = <String, _RemoteChannel>{};
  final _workers = <int, _RemoteWorker>{};
  var _nextWorker = 0;

  Future<HostConnection> _connect() => _connection ??= _start();

  Future<HostConnection> _start() async {
    try {
      final connection = await _launch();
      final current = _connection;
      connection.frames.listen(_route);
      // Only the process still in use going is a loss: one let go of, idle,
      // ends the same way and takes nothing with it.
      unawaited(
        connection.done.then((_) {
          if (identical(_connection, current)) _gone();
        }),
      );
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
      worker._ended(const ModelProcessGone());
    }
    _workers.clear();
    for (final channel in _channels.values) {
      channel._gone();
    }
    // Every holder hears it went, and none of them still holds it: a lease
    // left out would keep the next process from ever going idle.
    for (final lease in [..._leases]) {
      lease.lose();
    }
  }

  @override
  ModelProcessLease hold() {
    _idleTimer?.cancel();
    _idleTimer = null;
    late final ModelProcessLease lease;
    lease = ModelProcessLease(() {
      _leases.remove(lease);
      if (_leases.isNotEmpty) return;
      _idleTimer = Timer(idle, () {
        _idleTimer = null;
        unawaited(_letGo());
      });
    });
    _leases.add(lease);
    return lease;
  }

  /// Closing the connection is what ends the process: it leaves when the app
  /// does, and a socket closed is the app gone as far as it can tell.
  Future<void> _letGo() async {
    final idle = _connection;
    _connection = null;
    if (idle == null) return;
    try {
      (await idle).close();
    } catch (_) {
      // It never connected, which leaves nothing to close.
    }
  }

  @override
  Future<int?> footprint() async {
    final connection = _connection;
    if (connection == null) return null;
    try {
      return await (await connection).call(
            modelHostChannel.name,
            "footprint",
            null,
          )
          as int?;
    } catch (_) {
      // Going, or gone: there is no figure to give.
      return null;
    }
  }

  @override
  ModelChannel channel(String name) =>
      _channels[name] ??= _RemoteChannel(this, name);

  @override
  Future<Worker> spawn(WorkerKind kind, List<Object?> argument) async {
    final lease = hold();
    final HostConnection connection;
    try {
      connection = await _connect();
    } catch (_) {
      lease.release();
      rethrow;
    }
    final id = _nextWorker++;
    final worker = _workers[id] = _RemoteWorker(
      connection,
      id,
      lease,
      onClose: () => _workers.remove(id),
    );
    connection.send(SpawnFrame(id, kind.name, argument));
    return worker;
  }
}

class _RemoteChannel implements ModelChannel {
  _RemoteChannel(this._host, this._name);

  final HelperModelProcess _host;
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
  void _gone() => _calls.addError(const ModelProcessGone());
}

class _RemoteWorker implements Worker {
  _RemoteWorker(
    this._connection,
    this._id,
    this._lease, {
    required this.onClose,
  });

  final HostConnection _connection;
  final int _id;

  /// Given up when the worker ends, however it ends.
  final ModelProcessLease _lease;
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
  /// why — its process went ([ModelProcessGone]) or it never started
  /// ([WorkerFailed]) — and the host has no business speaking the worker's
  /// vocabulary to say so.
  void _ended([Object? error]) {
    _lease.release();
    if (_out.isClosed) return;
    if (error != null) _out.addError(error);
    unawaited(_out.close());
  }
}
