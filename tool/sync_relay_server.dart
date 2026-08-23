// A dumb relay Entoli can pair through: rooms addressed by a token both
// sides already know, messages forwarded verbatim between the two roles.
// Sees nothing readable — see `lib/data/sync/signaling/relay_signaler.dart`
// for what the clients put in it.
//
// Run it anywhere a WebSocket can be reached:
//
//   dart run tool/sync_relay_server.dart --port 8090
import "dart:async";
import "dart:convert";
import "dart:io";

void main(List<String> args) {
  final port = args.contains("--port")
      ? int.parse(args[args.indexOf("--port") + 1])
      : 8090;
  RelayServer().start(port).then((_) =>
      stdout.writeln("entoli relay listening on ws://0.0.0.0:$port"));
}

class RelayServer {
  // room -> role -> socket. Two roles per room is all the protocol has.
  final _rooms = <String, Map<String, WebSocket>>{};

  /// Binds and starts serving. Returns the server so a caller can find the
  /// port it was given (pass 0 for one of the OS's) and close it again — the
  /// tests run this exact class rather than a copy of it.
  Future<HttpServer> start(int port, {InternetAddress? address}) async {
    final server =
        await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    server.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        _adopt(socket);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    }, onError: (_) {});
    return server;
  }

  void _adopt(WebSocket socket) {
    String? room;
    String? role;

    socket.listen(
      (data) {
        if (data is! String) return;
        if (room == null) {
          try {
            final join = jsonDecode(data) as Map<String, dynamic>;
            room = join["join"] as String?;
            role = join["role"] as String?;
          } catch (_) {}
          if (room == null || !{"i", "j"}.contains(role)) {
            socket.close();
            return;
          }
          // A reconnecting role replaces its predecessor rather than piling on.
          _rooms.putIfAbsent(room!, () => {})[role!] = socket;
          return;
        }
        final peer = _rooms[room]?[role == "i" ? "j" : "i"];
        peer?.add(data);
      },
      onError: (_) {},
      onDone: () {
        if (room != null && role != null) {
          final occupants = _rooms[room];
          if (occupants?[role] == socket) occupants?.remove(role);
          if (occupants != null && occupants.isEmpty) _rooms.remove(room);
        }
      },
    );
  }
}
