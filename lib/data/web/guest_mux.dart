/// The page's end of `entoli-mux` (`tool/web/linux/entoli-mux.c`): processes
/// in the browser's Linux, each one a stream of output and an exit code, all
/// of them over one serial line. Pure Dart, so the shell above it is tested on
/// the VM against a fake guest.
library;

import "dart:async";
import "dart:convert";

/// A guest that could not start what it was asked to: no such program, or a
/// working directory that is not there.
class GuestSpawnFailure implements Exception {
  const GuestSpawnFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One process in the guest, the way `Process` is one on the machine.
class GuestProcess {
  GuestProcess._(this._mux, this.id) {
    // A process nobody waited on dying with the guest is not an error.
    _exit.future.ignore();
  }

  final GuestMux _mux;
  final int id;

  final _output = StreamController<List<int>>();
  final _exit = Completer<int>();
  final _outputDone = Completer<void>();

  /// stdout and stderr together, merged in the guest in the order printed.
  Stream<List<int>> get output => _output.stream;

  /// Its exit code, or 128 plus the signal that ended it. Fails with a
  /// [GuestSpawnFailure] where it never started, and with a [StateError]
  /// where the guest itself went away under it.
  Future<int> get exitCode => _exit.future;

  /// Completes when the output is closed, which is later than the exit where
  /// a child it left behind still holds the pipe.
  Future<void> get outputDone => _outputDone.future;

  /// The line carries a frame per call; a large write is cut so no one frame
  /// holds the line for long.
  void write(List<int> bytes) {
    for (var i = 0; i < bytes.length; i += _writeChunk) {
      final end = i + _writeChunk < bytes.length ? i + _writeChunk : bytes.length;
      _mux._send("I $id ${base64.encode(bytes.sublist(i, end))}");
    }
  }

  void closeInput() => _mux._send("C $id");

  /// Delivered to the process's whole group, which the guest made it the
  /// leader of.
  void signal(int signal) => _mux._send("K $id $signal");

  static const _writeChunk = 48 * 1024;

  void _data(List<int> bytes) {
    if (!_output.isClosed) _output.add(bytes);
  }

  void _closeOutput() {
    if (!_output.isClosed) unawaited(_output.close());
    if (!_outputDone.isCompleted) _outputDone.complete();
  }

  void _exited(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  void _fail(Object error) {
    if (!_exit.isCompleted) _exit.completeError(error);
    _closeOutput();
  }

  bool get _settled => _exit.isCompleted && _outputDone.isCompleted;
}

/// The other end of the line. [receive] is fed every line the guest writes;
/// [_send] writes one back.
class GuestMux {
  GuestMux(this._send) {
    _ready.future.ignore();
  }

  final void Function(String line) _send;

  final _ready = Completer<void>();
  final Map<int, GuestProcess> _processes = {};
  int _next = 1;
  bool _closed = false;

  /// Completes at the guest's first word: `entoli-mux` says `R` as it starts
  /// and answers a [ping] with `P`, so a page that missed the first hears the
  /// second.
  Future<void> get ready => _ready.future;

  bool get isReady => _ready.isCompleted;

  void ping() => _send("P");

  void receive(String line) {
    final fields = line.split(" ");
    switch (fields.first) {
      case "R" || "P":
        if (!_ready.isCompleted) _ready.complete();
        return;
    }
    if (fields.length < 2) return;
    final id = int.tryParse(fields[1]);
    final process = id == null ? null : _processes[id];
    if (process == null) return;
    switch (fields.first) {
      case "D" when fields.length > 2:
        process._data(base64.decode(fields[2]));
      case "E":
        process._closeOutput();
      case "X" when fields.length > 2:
        process._exited(int.tryParse(fields[2]) ?? -1);
      case "F" when fields.length > 2:
        process._fail(
            GuestSpawnFailure(utf8.decode(base64.decode(fields[2]))));
    }
    if (process._settled) _processes.remove(id);
  }

  /// [argv]'s first entry is a path in the guest: nothing searches `PATH`.
  GuestProcess start(List<String> argv,
      {required String cwd, required Map<String, String> environment}) {
    final process = GuestProcess._(this, _next++);
    if (_closed) {
      process._fail(StateError("The Linux in this page has stopped."));
      return process;
    }
    _processes[process.id] = process;
    String field(Iterable<String> parts) =>
        base64.encode(utf8.encode(parts.join("\u0000")));
    _send("O ${process.id} ${field(argv)} ${field([cwd])} "
        "${field([for (final e in environment.entries) "${e.key}=${e.value}"])}");
    return process;
  }

  /// The guest is gone; so is every process that was running in it.
  void close(String why) {
    _closed = true;
    for (final process in _processes.values) {
      process._fail(StateError(why));
    }
    _processes.clear();
    if (!_ready.isCompleted) _ready.completeError(StateError(why));
  }
}
