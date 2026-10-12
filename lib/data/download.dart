import "dart:async";
import "dart:io";

import "package:http/http.dart" as http;

import "../../core/tls.dart";

import "../domain/download.dart";

/// Fetching something big onto the disk, reported as it goes and abandoned
/// whole if the listener leaves. Both stores that download — the voice models
/// and the Linux the agent runs commands in — are this plus what they do with
/// the bytes afterwards.
///
/// The part worth sharing is not the fetching, which is a loop, but the
/// **cancellation**: a listener that goes away has to take the half-written
/// directory with it, and nothing is left to tell. Two copies of that is one
/// copy that gets fixed. Cancel's own future is the teardown's — awaiting it
/// joins the discard instead of watching the disk for it.
class DownloadRun {
  DownloadRun({required this.run, required this.discard, http.Client? client})
      : _client = client ?? tlsClient() {
    _out = StreamController<DownloadProgress>(
      onListen: () => run(this).then(
        (_) async {
          _client.close();
          // Cancelling closes the stream from the other end, so there is
          // nobody left to tell — only the half-written directory to
          // remove, and its removal is what cancel's own future waits on.
          if (_cancelled) {
            await discard();
            _tornDown.complete();
          } else {
            // Completed before the controller's own close: a full drain
            // auto-cancels once the done event lands, the cancel's future
            // is this teardown's, and close's future would wait on that
            // cancel — the two waits cycle unless the completion runs
            // first.
            _tornDown.complete();
            await _out.close();
          }
        },
        onError: (Object e) async {
          await discard();
          _client.close();
          // Same order as the value arm: the completion is the one future
          // a cancelling listener's cancel waits on.
          _tornDown.complete();
          if (!_out.isClosed) {
            _out.addError(e);
            await _out.close();
          }
        },
      ),
      onCancel: () {
        _cancelled = true;
        _client.close();
        // The close unblocks whatever the run wrote toward — the response it
        // was reading is over — so the discard after it is a bounded chain
        // of the run's own steps, and this is the one event a caller can
        // await rather than poll the filesystem for.
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

  /// The run's own ending, one step past [discard]: a subscription's cancel
  /// answers this, so whoever awaits the cancellation is awaited past the
  /// half-written directory being gone rather than left to poll for it.
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
