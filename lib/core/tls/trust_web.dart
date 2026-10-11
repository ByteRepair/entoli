// The web-half of the TLS trust: a browser's TLS is its own, its root set
// bundled by the browser, and CORS the only thing between the app and a
// host — nothing here to fall back from, and nothing reading a store.
import "package:http/browser_client.dart";
import "package:http/http.dart" as http;
import "package:web_socket_channel/web_socket_channel.dart";

http.Client tlsClient() => BrowserClient();

Future<WebSocketChannel> tlsWebSocketChannel(
  Uri uri, {
  Duration? readyTimeout,
}) async {
  final channel = WebSocketChannel.connect(uri);
  final ready =
      readyTimeout == null ? channel.ready : channel.ready.timeout(readyTimeout);
  await ready;
  return channel;
}