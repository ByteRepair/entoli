import "dart:convert";
import "dart:io";
import "dart:math";

import "package:path/path.dart" as p;

import "host_connection.dart";
import "host_frame.dart";
import "model_host_server.dart";

/// Starts the model host — this app's own executable, launched again as
/// `entoli-models <socket>` — and answers its connection once it has proved
/// it is the one started here.
///
/// The socket is a Unix one in a directory only this user can enter, and the
/// host must open with the key it was handed: another process on the machine
/// can neither find the path nor pass for the host.
class HelperProcess {
  HelperProcess._();

  static const _connectTimeout = Duration(seconds: 30);

  static Future<HostConnection> launch() async {
    // The host is this app's executable run again, which only an app bundle
    // has: under `flutter test` it is the tester, which would sit waiting on
    // arguments it does not know until the connect timed out.
    final executable = Platform.resolvedExecutable;
    if (!executable.contains(".app/Contents/MacOS/")) {
      throw StateError("No app bundle to start a model host from.");
    }
    final bundle = executable.substring(0, executable.indexOf(".app/") + 4);
    final dir = await Directory.systemTemp.createTemp("entoli-models-");
    final path = p.join(dir.path, "s");
    final key = _newKey();
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    try {
      // Through LaunchServices rather than as a child: a child is this app's
      // to macOS, its GPU work scheduled as this app's own beside the
      // window's frames. Opened, it is an app of its own. It watches [pid]
      // for this app going, since its parent is now launchd.
      final opened = await Process.run("/usr/bin/open", [
        "-n",
        "-g",
        "--env",
        "$modelHostKeyVariable=$key",
        "-a",
        bundle,
        "--args",
        "entoli-models",
        path,
        "$pid",
      ]);
      if (opened.exitCode != 0) {
        throw StateError("The model host would not open: ${opened.stderr}");
      }
      final socket = await server.first.timeout(_connectTimeout);
      final connection = HostConnection(socket);
      final hello = await connection.frames.first.timeout(_connectTimeout);
      if (hello is! HelloFrame || hello.key != key) {
        // Closed, the host leaves on its own.
        connection.close();
        throw StateError("The model host did not identify itself.");
      }
      return connection;
    } finally {
      // Connected or not, nothing else is let in, and the path goes with it.
      await server.close();
      await dir.delete(recursive: true);
    }
  }

  static String _newKey() {
    final random = Random.secure();
    return base64Url.encode(List.generate(24, (_) => random.nextInt(256)));
  }
}
