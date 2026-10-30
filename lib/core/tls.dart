// The TLS trust the app's network calls are made under: the system's root
// store first, the bundled Mozilla set once behind it.
//
// Dart reads the OS's own root store for its HTTPS trust. On Windows the
// store's population is schannel's, on demand, and a dart:io handshake never
// asks for it — so a machine whose store has not been refreshed past the root
// an endpoint now chains under fails its handshake with "unable to get local
// issuer certificate" however correct the chain that arrived: a fresh VM, an
// LTSC or trimmed image, a box between updates. A browser answers the same
// problem by carrying its own audited root set, and the fallback below does
// the same, on Windows only — elsewhere the store is maintained as the OS's.
//
// The shape is security by the same order everywhere: the system's store is
// the first and ordinary answer (a network a machine in-spects, whose root
// sits in that store, works there); the fallback is the certificate
// verification failing alone, and the second verify is against Mozilla's
// audited set, which a machine-in-the-middle chain is not on. A chain refused
// by both fails as it would have.
//
// The bundled set is a circumvention, not a choice: dart-lang/sdk#52266
// (https://github.com/dart-lang/sdk/issues/52266) is the Dart issue it exists
// for — a dart:io handshake never triggering the store's population — and
// once that is fixed, discard assets/certs/cacert.pem and the fallback here
// with it; tracked on our end by #294.
import "dart:io";

import "package:flutter/services.dart" show rootBundle;
import "package:http/http.dart" as http;
import "package:http/io_client.dart";
import "package:web_socket_channel/io.dart";
import "package:web_socket_channel/web_socket_channel.dart";

/// The Mozilla root list by curl's bundling, the only place it is named.
const _mozillaAsset = "assets/certs/cacert.pem";

/// The client a provider, a download, a search or the marketplace reaches a
/// host with. See [TlsFallbackClient].
http.Client tlsClient() => TlsFallbackClient(http.Client());

/// The relay's WebSocket, under the same trust and the same fallback: the
/// first connect waits on the store's verdict, and where it is the
/// certificate verification that refused, one reconnect under the bundled set.
/// [readyTimeout] bounds each attempt's wait on the store, the first as the
/// caller's patience and the second's its own.
Future<WebSocketChannel> tlsWebSocketChannel(
  Uri uri, {
  Duration? readyTimeout,
}) async {
  final channel = WebSocketChannel.connect(uri);
  try {
    final ready = readyTimeout == null
        ? channel.ready
        : channel.ready.timeout(readyTimeout);
    await ready;
  } catch (e) {
    if (!Platform.isWindows || !_isCertificateVerify(e)) rethrow;
    final client = HttpClient(context: await _mozillaRootContext());
    try {
      final connect = WebSocket.connect(uri.toString(), customClient: client);
      final socket = readyTimeout == null
          ? await connect
          : await connect.timeout(readyTimeout);
      return IOWebSocketChannel(socket);
    } on Object {
      // close cancels the attempt's pending socket tasks, and the caller
      // reads this attempt's own failure rather than the first refusal.
      client.close(force: true);
      rethrow;
    }
  }
  return channel;
}

Future<SecurityContext>? _mozillaRootMemo;

/// The `SecurityContext` whose trust is exactly the bundled Mozilla set,
/// read once: every client this file builds shares it, and none of them reads
/// the asset until the system's store has refused.
Future<SecurityContext> _mozillaRootContext() =>
    _mozillaRootMemo ??= _loadMozillaRootContext();

Future<SecurityContext> _loadMozillaRootContext() async {
  final data = await rootBundle.load(_mozillaAsset);
  // The bundle's ByteData may be a view into a larger buffer, at an offset.
  return SecurityContext()..setTrustedCertificatesBytes(
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
  );
}

/// [See "Reaching a provider" in lib/data/builtin/llm/AGENTS.md for the
/// client this wraps.]
///
/// Sends under the system's trust; where that handshake dies on the
/// certificate verification alone — and only there, so every other reason a
/// handshake fails keeps its original error — the same request runs again
/// under the bundled set, and this client is the bundled-set client from then
/// on, a per-endpoint fact: the host whose verify refused does not change
/// under the same instance. The retry is a fresh copy of the request, not
/// the first send's instance: `finalize` is the first thing a `package:http`
/// send does, before the socket the handshake dies on, so by the time this
/// sees the refusal the original is unsendable — a second finalize answers
/// "Can't finalize a finalized Request." before any connection starts.
class TlsFallbackClient extends http.BaseClient {
  TlsFallbackClient(this._client, {bool? windows, http.Client? fallback})
    : _windows = windows ?? Platform.isWindows,
      _bundledFallback = fallback;

  final http.Client _client;
  final bool _windows;

  /// The tests' way to hand the bundled set's client over: a wrapper built
  /// with one never loads the asset at all.
  final http.Client? _bundledFallback;

  Future<http.Client>? _building;

  /// The host whose certificate verify refused and now verifies under the
  /// bundled set — a map, not a flag: one client instance can reach two
  /// hosts (the marketplace's index and its raw entries), and their verdicts
  /// are separate facts.
  final Map<String, http.Client> _bundledHosts = {};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final pinned = _bundledHosts[request.url.host];
    if (pinned != null) return pinned.send(request);
    try {
      return await _client.send(request);
    } on HandshakeException catch (e) {
      if (!_windows || !_isCertificateVerify(e)) rethrow;
      try {
        final client = await _mozillaClient();
        _bundledHosts[request.url.host] = client;
        return await client.send(_replayable(request));
      } on Object {
        // The bundled set refused too: the original refusal is the one a
        // turn reads, and no third trust is claimed.
        throw e;
      }
    }
  }

  @override
  void close() {
    _client.close();
    for (final client in _bundledHosts.values) {
      client.close();
    }
  }

  /// The bundled set's client, built once, on the first
  /// certificate-verify refusal at the earliest: nothing here loads the
  /// asset for a machine whose store answered.
  Future<http.Client> _mozillaClient() => _building ??= _bundledFallback != null
      ? Future.value(_bundledFallback)
      : _buildMozillaClient();

  static Future<http.Client> _buildMozillaClient() async {
    final context = await _mozillaRootContext();
    return IOClient(HttpClient(context: context));
  }

  // The predicate is top-level, below, because the WebSocket's ready fails
  // from a helper that is in no class: both the http send and that ready come
  // through one text check, so a wrapping layer's rewording does not get past
  // it.
}

/// A request the retry's send may finalize itself. The first send's
/// `finalize` has already run by the time the handshake died, and a second
/// send of that instance throws at finalize before any connection starts;
/// a buffered `http.Request`'s method, url, headers and body bytes all stay
/// readable after, which is all a copy needs. Only a buffered one replays —
/// it is what every caller sends — anything else arrives again as before
/// and stays the caller's.
http.BaseRequest _replayable(http.BaseRequest request) {
  if (request is! http.Request) return request;
  return http.Request(request.method, request.url)
    ..headers.addAll(request.headers)
    ..bodyBytes = request.bodyBytes
    ..followRedirects = request.followRedirects
    ..maxRedirects = request.maxRedirects
    ..persistentConnection = request.persistentConnection;
}

bool _isCertificateVerify(Object e) =>
    "$e".contains("CERTIFICATE_VERIFY_FAILED");
