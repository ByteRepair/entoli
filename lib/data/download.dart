import "dart:async";
import "dart:io";

import "package:http/http.dart" as http;

import "../core/tls.dart";
import "../domain/download.dart";

/// Fetching something big onto the disk, reported as it goes and abandoned
/// whole if the listener leaves: a cancelled listener takes the half-written
/// directory with it, and cancel's own future waits for that discard.
class DownloadRun {
  DownloadRun({required this.run, required this.discard, http.Client? client})
      : _client = client ?? tlsClient() {
    _out = StreamController<DownloadProgress>(
      onListen: () => run(this).then(
        (_) async {
          _client.close();
          if (_cancelled) {
            await discard();
            _tornDown.complete();
          } else {
            // Completed before close: a full drain auto-cancels on the done
            // event, that cancel waits on this, and close waits on the
            // cancel — the waits cycle unless this runs first.
            _tornDown.complete();
            await _out.close();
          }
        },
        onError: (Object e) async {
          await discard();
          _client.close();
          _tornDown.complete();
          if (!_out.isClosed) {
            _out.addError(e);
            await _out.close();
          }
        },
      ),
      onCancel: () {
        _cancelled = true;
        // Closing ends the response the run was reading, so the run and its
        // discard finish promptly.
        _client.close();
        return _tornDown.future;
      },
    );
  }

  /// The download itself: [fetch] what it needs, [report] where it has got to,
  /// and check [cancelled] wherever it would otherwise carry on doing work
  /// nobody is waiting for.
  final Future<void> Function(DownloadRun run) run;

  /// Undo a half-done install. Called when the listener leaves and when the
  /// run throws, which are the two ways this ends badly.
  final Future<void> Function() discard;

  /// Completes once the run, and any [discard], is over; a cancel returns it.
  final _tornDown = Completer<void>();

  final http.Client _client;
  late final StreamController<DownloadProgress> _out;
  var _cancelled = false;

  Stream<DownloadProgress> get stream => _out.stream;

  /// Whether the listener has gone. The run is expected to check this after
  /// anything slow and give up.
  bool get cancelled => _cancelled;

  void report(DownloadProgress progress) => _out.add(progress);

  /// One file, streamed to disk, and how many bytes it turned out to be.
  /// [done] is what earlier files already added up to and [total] what they
  /// will in the end, so a model of four files reports one bar rather than
  /// four. [watch] sees every chunk on the way past — a checksum, where the
  /// caller wants one, without a second read of the file.
  Future<int> fetch({
    required String url,
    required String to,
    required int total,
    int done = 0,
    Sink<List<int>>? watch,
  }) async {
    final response = await _client.send(http.Request("GET", Uri.parse(url)));
    if (response.statusCode != 200) {
      throw HttpException("${response.statusCode} for $url");
    }
    final sink = File(to).openWrite();
    var at = 0;
    var told = 0;
    try {
      // `addStream` rather than `add` per chunk: a device whose flash is slower
      // than its radio would otherwise queue the difference on the heap, for
      // the length of a 250 MB download.
      await sink.addStream(response.stream.takeWhile((_) => !_cancelled).map((chunk) {
        watch?.add(chunk);
        at += chunk.length;
        // Every chunk would be thousands of reports, and each one rebuilds a
        // notification through five binder calls — for a bar with a hundred
        // pixels to move.
        if (at - told >= _reportEvery) {
          told = at;
          report(DownloadProgress(received: done + at, total: total));
        }
        return chunk;
      }));
      report(DownloadProgress(received: done + at, total: total));
    } finally {
      await sink.close();
    }
    return at;
  }

  /// How far the bar moves before it is worth saying so.
  static const _reportEvery = 1 << 20;
}
