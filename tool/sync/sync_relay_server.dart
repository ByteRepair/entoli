// A dumb relay Entoli can pair through: rooms addressed by a token both
// sides already know, messages forwarded verbatim between the two roles.
// Sees nothing readable — see `lib/data/sync/signaling/relay_signaler.dart`
// for what the clients put in it.
//
// Run it anywhere a WebSocket can be reached:
//
//   dart run tool/sync/sync_relay_server.dart --port 8090
import "dart:async";
import "dart:convert";
import "dart:io";

void main(List<String> args) {
  final port = args.contains("--port")
      ? int.parse(args[args.indexOf("--port") + 1])
      : 8090;
  RelayServer()
      .start(port)
      .then(
        (_) => stdout.writeln("entoli relay listening on ws://0.0.0.0:$port"),
      );
}

/// One side of a room, as the forwarding sees it. A WebSocket in earnest.
abstract interface class RelayPeer {
  /// Everything that side sent, done when it goes away.
  Stream<Object?> get incoming;

  void send(String message);

  void close();
}

/// Who is in which room, and what gets passed to whom — all of the relay that
/// is worth checking, with no socket in it. The tests drive this directly
/// rather than binding a port and dialling themselves through it.
class RelayRooms {
  // room -> role -> peer. Two roles per room is all the protocol has.
  final _rooms = <String, Map<String, RelayPeer>>{};

  void adopt(RelayPeer peer) {
    String? room;
    String? role;

    peer.incoming.listen(
      (data) {
        if (data is! String) return;
        if (room == null) {
          try {
            final join = jsonDecode(data) as Map<String, dynamic>;
            room = join["join"] as String?;
            role = join["role"] as String?;
          } catch (_) {}
          if (room == null || !{"i", "j"}.contains(role)) {
            peer.close();
            return;
          }
          // A reconnecting role replaces its predecessor rather than piling on.
          _rooms.putIfAbsent(room!, () => {})[role!] = peer;
          return;
        }
        _rooms[room]?[role == "i" ? "j" : "i"]?.send(data);
      },
      onError: (_) {},
      onDone: () {
        if (room == null || role == null) return;
        final occupants = _rooms[room];
        if (occupants?[role] == peer) occupants?.remove(role);
        if (occupants != null && occupants.isEmpty) _rooms.remove(room);
      },
    );
  }
}

class RelayServer {
  final rooms = RelayRooms();

  /// Binds and starts serving. Returns the server so a caller can find the
  /// port it was given and close it again.
  Future<HttpServer> start(int port) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    server.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        rooms.adopt(_SocketPeer(await WebSocketTransformer.upgrade(request)));
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    }, onError: (_) {});
    return server;
  }
}

class _SocketPeer implements RelayPeer {
  _SocketPeer(this._socket);

  final WebSocket _socket;

  @override
  Stream<Object?> get incoming => _socket;

  @override
  void send(String message) => _socket.add(message);

  @override
  void close() => _socket.close();
}
