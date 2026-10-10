// The io-half of the TLS trust: the system's root store first, the bundled
// Mozilla set once behind it.
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
http.Client tlsClient([http.Client? primary]) =>
    TlsFallbackClient(primary ?? http.Client());

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
    final client = HttpClient(context: await mozillaRootContext());
    final socket =
        await WebSocket.connect(uri.toString(), customClient: client);
    return IOWebSocketChannel(socket);
  }
  return channel;
}

/// A `SecurityContext` whose trust is exactly the bundled Mozilla set.
Future<SecurityContext> mozillaRootContext() async {
  final data = await rootBundle.load(_mozillaAsset);
  return SecurityContext()
    ..setTrustedCertificatesBytes(data.buffer.asUint8List());
}

/// [See "Reaching a provider" in lib/data/builtin/llm/AGENTS.md for the
/// client this wraps.]
///
/// Sends under the system's trust; where that handshake dies on the
/// certificate verification alone — and only there, so every other reason a
/// handshake fails keeps its original error — the same request runs again
/// under the bundled set, and this client is the bundled-set client from then
/// on, a per-endpoint fact: the host whose verify refused does not change
/// under the same instance. The request is re-sent rather than rebuilt, the
/// TLS handshake being where a `dart:io` client opens the socket, before its
/// body is read.
class TlsFallbackClient extends http.BaseClient {
  TlsFallbackClient(this._client, {bool? windows, http.Client? fallback})
      : _windows = windows ?? Platform.isWindows,
        _bundledFallback = fallback;

  final http.Client _client;
  final bool _windows;

  /// The tests' way to hand the bundled set's client over: a wrapper built
  /// with one never loads the asset at all.
  final http.Client? _bundledFallback;

  http.Client? _fallback;
  Future<http.Client>? _building;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final fallback = _fallback;
    if (fallback != null) {
      try {
        return await fallback.send(request);
      } on HandshakeException {
        rethrow;
      }
    }
    try {
      return await _client.send(request);
    } on HandshakeException catch (e) {
      if (!_windows || !_isCertificateVerify(e)) rethrow;
      try {
        final client = await _mozillaClient();
        _fallback = client;
        return await client.send(request);
      } on Object {
        // The bundled set refused too: the original refusal is the one a
        // turn reads, and no third trust is claimed.
        rethrow;
      }
    }
  }

  @override
  void close() {
    _client.close();
    _fallback?.close();
  }

  /// The bundled set's client, built once, on the first
  /// certificate-verify refusal at the earliest: nothing here loads the
  /// asset for a machine whose store answered.
  Future<http.Client> _mozillaClient() =>
      _building ??= _bundledFallback != null
          ? Future.value(_bundledFallback)
          : _buildMozillaClient();

  static Future<http.Client> _buildMozillaClient() async {
    final context = await mozillaRootContext();
    return IOClient(HttpClient(context: context));
  }

  // The predicate is top-level, below, because the WebSocket's ready fails
  // from a helper that is in no class: both the http send and that ready come
  // through one text check, so a wrapping layer's rewording does not get past
  // it.
}

bool _isCertificateVerify(Object e) =>
    "$e".contains("CERTIFICATE_VERIFY_FAILED");