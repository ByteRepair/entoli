import "dart:async";
import "dart:io";

import "package:crypto/crypto.dart";
import "package:http/http.dart" as http;

/// An install as a stream: a client to fetch with, a way to ask whether the
/// listener is still there, and somewhere to report progress.
///
/// The three catalogs — a voice model, a Linux, a model to run on the device —
/// were three copies of this, and what they copied was the part that is easy to
/// get subtly wrong rather than the part that differs: **cancelling is the
/// listener going away**, so the half-written directory has to be removed with
/// nobody left to tell, and the client has to be closed on all three exits
/// without adding to a controller that is already closed.
///
/// [discard] is what a cancelled or failed install leaves nothing behind with.
Stream<P> downloadStream<P>({
  required Future<void> Function(
    http.Client client,
    bool Function() cancelled,
    void Function(P) report,
  ) run,
  required Future<void> Function() discard,
}) {
  final client = http.Client();
  var cancelled = false;
  late StreamController<P> out;

  out = StreamController<P>(
    onListen: () => run(client, () => cancelled, out.add).then(
      (_) async {
        client.close();
        // Cancelling closes the stream from the other end, so there is nobody
        // left to tell — only the half-written directory to remove.
        if (cancelled) return discard();
        await out.close();
      },
      onError: (Object e) async {
        await discard();
        client.close();
        if (!out.isClosed) {
          out.addError(e);
          await out.close();
        }
      },
    ),
    onCancel: () {
      cancelled = true;
      client.close();
    },
  );
  return out.stream;
}

/// One file, streamed to disk, reporting as it goes and hashed on the way past
/// where the caller has something to check it against.
///
/// The three things Entoli downloads — a voice model, a Linux, and a model to
/// run on the device — are three catalogs and one of these, since what differs
/// between them is what lands on disk rather than how it arrives. Hashing here
/// rather than reading the file back afterwards: it is the same bytes and a
/// phone reads them slowly.
///
/// [cancelled] is polled per chunk rather than being a token, because the only
/// thing that cancels one of these is its stream controller losing its listener.
Future<({int bytes, String? sha256})> fetchToFile({
  required http.Client client,
  required String url,
  required String to,
  required void Function(int) report,
  required bool Function() cancelled,
  bool hash = false,
  int reportEvery = _reportEvery,
}) async {
  final response = await client.send(http.Request("GET", Uri.parse(url)));
  if (response.statusCode != 200) {
    throw HttpException("${response.statusCode} for $url");
  }
  final sink = File(to).openWrite();
  final digest = hash ? _Sha256Sink() : null;
  final hashing = digest == null ? null : sha256.startChunkedConversion(digest);
  var at = 0;
  var told = 0;
  try {
    // `addStream` rather than `add` per chunk: a device whose flash is slower
    // than its radio would otherwise queue the difference on the heap, for the
    // length of a two-gigabyte download.
    await sink.addStream(response.stream.takeWhile((_) => !cancelled()).map((chunk) {
      hashing?.add(chunk);
      at += chunk.length;
      // Every chunk would be thousands of reports, and each one rebuilds a
      // notification through five binder calls — for a bar with a hundred
      // pixels to move.
      if (at - told >= _reportEvery) {
        told = at;
        report(at);
      }
      return chunk;
    }));
    report(at);
  } finally {
    await sink.close();
    hashing?.close();
  }
  return (bytes: at, sha256: digest == null ? null : "${digest.digest}");
}

/// How far the bar moves before it is worth saying so. A megabyte suits the
/// files this was written for; a caller fetching gigabytes passes its own, since
/// each report is a platform channel call and a notification rebuild — see
/// [reportsFor].
const _reportEvery = 1 << 20;

/// A report threshold for a download of [total] bytes: enough for a bar to move
/// smoothly and no more. A 2 GB model at the default would be two thousand
/// notification rebuilds, most of them dropped by Android for arriving faster
/// than it will draw them.
int reportsFor(int total) => total ~/ 200 < _reportEvery ? _reportEvery : total ~/ 200;

/// Where the hash of the download lands. `package:convert` has one of these and
/// is not a dependency for four lines.
class _Sha256Sink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
