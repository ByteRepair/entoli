import "dart:async";

import "package:http/http.dart" as http;

/// An HTTP client with no socket under it. [bodies] is what each path answers
/// with, in the pieces it arrives in; anything else refuses the connection,
/// which is what dialling something that is not there does.
///
/// [hold] blocks between the pieces, so a test can cancel or stop something
/// mid-response — and closing the client ends the response where it got to,
/// which is what a real one does and what a cancelled download is relying on
/// to stop.
class FakeNetwork extends http.BaseClient {
  FakeNetwork(
    this.bodies, {
    this.headers = const {},
    this.missingAs404 = false,
  });

  /// True where an unlisted path answers 404 rather than refusing — what a
  /// server with a directory tree (GitHub Pages) says about a file that is
  /// not there. The marketplace's entry files lean on that: a missing
  /// `profile.png` is an answer, not a failure.
  final bool missingAs404;

  /// The same for whole bodies, which arrive in two halves — a download.
  factory FakeNetwork.inHalves(Map<String, List<int>> bodies) => FakeNetwork({
    for (final MapEntry(:key, :value) in bodies.entries)
      key: [
        value.sublist(0, value.length ~/ 2),
        value.sublist(value.length ~/ 2),
      ],
  });

  /// Any host: which one it is has never been what these tests are about.
  static const host = "http://nowhere.test";

  final Map<String, List<List<int>>> bodies;
  final Map<String, String> headers;

  /// One per request that was answered.
  var asked = 0;

  /// Whether [close] has run, which later hold-point arrivals check — the
  /// close completed whoever was waiting then, and the hole is the response
  /// that reaches the hold only after it.
  var _closed = false;

  /// Completed to let held responses finish. Null means nothing is held.
  Completer<void>? hold;

  /// One per response still waiting on [hold], so closing the client abandons
  /// those and leaves later ones alone.
  final _abandoned = <Completer<void>>[];

  String url(String path) => "$host$path";

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final pieces = bodies[request.url.path];
    if (pieces == null) {
      if (missingAs404) {
        asked++;
        return http.StreamedResponse(
          const Stream.empty(),
          404,
          headers: headers,
          request: request,
        );
      }
      throw http.ClientException("connection refused", request.url);
    }
    asked++;
    return http.StreamedResponse(
      _pieces(pieces),
      200,
      headers: headers,
      request: request,
    );
  }

  Stream<List<int>> _pieces(List<List<int>> pieces) async* {
    for (var i = 0; i < pieces.length; i++) {
      if (i > 0 && !await _carriesOn()) return;
      yield pieces[i];
    }
  }

  /// Whether the response goes on: false once the client was closed, whether
  /// it was stopped in the hold when that happened or arrived there after.
  Future<bool> _carriesOn() async {
    final held = hold;
    if (held == null) return true;
    final abandoned = Completer<void>();
    _abandoned.add(abandoned);
    if (_closed) return false;
    await Future.any([held.future, abandoned.future]);
    if (abandoned.isCompleted) return false;
    _abandoned.remove(abandoned);
    return true;
  }

  @override
  void close() {
    _closed = true;
    for (final abandoned in _abandoned) {
      if (!abandoned.isCompleted) abandoned.complete();
    }
    _abandoned.clear();
  }
}
