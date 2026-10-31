import "dart:async";
import "dart:io";

import "package:flutter/services.dart";
import "package:flutter/widgets.dart" show WidgetsFlutterBinding;

import "../../core/log.dart";
import "host_connection.dart";
import "host_frame.dart";
import "model_process.dart";
import "worker.dart";

/// The environment variable the app hands the host its key in. Beside the
/// arguments rather than in them, where `ps` would show it.
const modelHostKeyVariable = "ENTOLI_MODEL_HOST_KEY";

/// The model host's half: what the app asks of [HelperModelProcess], done in
/// this process. Calls go to this process's own native channels, what those
/// say unasked goes back as events, and workers run in isolates here.
class ModelHostServer {
  ModelHostServer(
    this._connection, {
    required List<MethodChannel> channels,
    required List<WorkerKind> workers,
  }) : _kinds = {for (final kind in workers) kind.name: kind} {
    for (final channel in [modelHostChannel, ...channels]) {
      final local = _channels[channel.name] = PlatformModelChannel(channel);
      local.calls.listen(
        (call) => _connection.send(
          EventFrame(channel.name, call.method, call.arguments),
        ),
      );
    }
    _connection.frames.listen(_receive);
    unawaited(_connection.done.then((_) => _closeWorkers()));
  }

  final HostConnection _connection;
  final Map<String, WorkerKind> _kinds;
  final _channels = <String, ModelChannel>{};

  /// Held as the spawn rather than the worker: what the app sends right
  /// after asking for one arrives before its isolate is up, and is queued
  /// behind the spawn in the order it came.
  final _workers = <int, Future<Worker>>{};

  /// The host process's whole life: connects to the app at [arguments]' socket
  /// path, serves until the app goes, then asks the native half to leave.
  static Future<void> run(
    List<String> arguments, {
    required List<MethodChannel> channels,
    required List<WorkerKind> workers,
  }) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      final socket = await Socket.connect(
        InternetAddress(arguments.first, type: InternetAddressType.unix),
        0,
      );
      final connection = HostConnection(socket)
        ..send(HelloFrame(Platform.environment[modelHostKeyVariable] ?? ""));
      ModelHostServer(connection, channels: channels, workers: workers);
      await connection.done;
    } catch (e) {
      logFailure("model-host", "could not reach the app", e);
    }
    await modelHostChannel.invokeMethod("quit");
  }

  void _receive(HostFrame frame) => switch (frame) {
    CallFrame() => unawaited(_answer(frame)),
    SpawnFrame() => unawaited(_spawn(frame)),
    PostFrame(:final worker, :final message) =>
      _workers[worker]?.then((w) => w.send(message)).ignore(),
    CloseFrame(:final worker) =>
      _workers.remove(worker)?.then((w) => w.close()).ignore(),
    _ => null,
  };

  Future<void> _answer(CallFrame call) async {
    final channel = _channels[call.channel];
    if (channel == null) {
      return _connection.send(
        FailFrame(call.id, "no-channel", "No channel ${call.channel} here."),
      );
    }
    try {
      final result = await channel.invokeMethod<Object?>(
        call.method,
        call.arguments,
      );
      _connection.send(ReplyFrame(call.id, result));
    } on PlatformException catch (e) {
      _connection.send(FailFrame(call.id, e.code, e.message));
    } on MissingPluginException catch (e) {
      _connection.send(FailFrame(call.id, "not-implemented", e.message));
    }
  }

  /// Registered before its first await, so a message the app sent straight
  /// after finds it. One that never starts is closed with the reason, which
  /// the app's end hands its owner as an error.
  Future<void> _spawn(SpawnFrame spawn) async {
    final kind = _kinds[spawn.kind];
    final starting = _workers[spawn.worker] = kind == null
        ? Future<Worker>.error(StateError("No worker named ${spawn.kind}."))
        : IsolateWorker.spawn(kind, spawn.argument);
    try {
      final worker = await starting;
      worker.messages.listen(
        (message) => _connection.send(PostFrame(spawn.worker, message)),
      );
    } catch (e) {
      _workers.remove(spawn.worker);
      logFailure("model-host", "worker ${spawn.kind} would not start", e);
      _connection.send(CloseFrame(spawn.worker, error: "$e"));
    }
  }

  void _closeWorkers() {
    for (final starting in _workers.values) {
      starting.then((w) => w.close()).ignore();
    }
    _workers.clear();
  }
}
