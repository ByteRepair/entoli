import "dart:io";

import "package:crypto/crypto.dart";
import "package:http/http.dart" as http;

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

/// How far the bar moves before it is worth saying so.
const _reportEvery = 1 << 20;

/// Where the hash of the download lands. `package:convert` has one of these and
/// is not a dependency for four lines.
class _Sha256Sink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}
