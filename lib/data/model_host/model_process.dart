import "dart:async";

import "package:flutter/services.dart";
import "package:entoli_core/model/model_process.dart";

import "host_connection.dart";
import "host_frame.dart";
import "worker.dart";

/// The host process's own native half: `quit`, which it is asked as it
/// leaves, and `footprint`, its memory as the app shows it. Served beside
/// whatever channels the host was given, since every host has one.
const modelHostChannel = MethodChannel("agent_chat/model_host");

/// The models in this process, everywhere but macOS: iOS cannot start a
/// process, and the other platforms' models are a server of their own or run
/// on the CPU. macOS runs them in a second process ([HelperModelProcess])
/// because MLX's GPU work in the process that draws the window starves the
/// window's frames: the GPU interleaves processes, not the queues of one.
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
      // Started by an ask that holds nothing — a channel call with no model
      // behind it — it waits out the idle time like any process let go of.
      if (_leases.isEmpty) _waitIdle();
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
    // A wait armed for the process that went would close the next one.
    _idleTimer?.cancel();
    _idleTimer = null;
    for (final worker in _workers.values) {
      worker._ended(const ModelProcessGone());
    }
    _workers.clear();
    for (final channel in _channels.values) {
      channel._gone();
    }
    // Every holder hears it went, and none of them still holds it: a lease
    // left out would keep the next process from ever going idle. Taken
    // rather than released, so no idle wait starts for a process that is
    // not there.
    final leases = [..._leases];
    _leases.clear();
    for (final lease in leases) {
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
      if (_leases.isEmpty) _waitIdle();
    });
    _leases.add(lease);
    return lease;
  }

  void _waitIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idle, () {
      _idleTimer = null;
      unawaited(_letGo());
    });
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
  _RemoteChannel(this._process, this._name);

  final HelperModelProcess _process;
  final String _name;
  final _calls = StreamController<MethodCall>.broadcast();

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    final connection = await _process._connect();
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
