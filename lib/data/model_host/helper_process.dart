import "dart:io";

import "package:flutter/services.dart";
import "package:path/path.dart" as p;

import "../../core/random_token.dart";
import "host_connection.dart";
import "host_frame.dart";
import "model_host_server.dart";

/// Starts the model host — `Contents/Helpers/Entoli Models.app`, this app's
/// executable in a background-only bundle of its own, launched as
/// `entoli-models <socket> <pid>` — and answers its connection once it has
/// proved it is the one started here.
///
/// The socket is a Unix one in a directory only this user can enter, and the
/// host must open with the key it was handed: another process on the machine
/// can neither find the path nor pass for the host.
class HelperProcess {
  HelperProcess._();

  static const _connectTimeout = Duration(seconds: 30);

  /// What opens the host: LaunchServices, from the native half.
  static const _launcher = MethodChannel("agent_chat/model_host_launcher");

  /// The helper bundle inside the app this process runs from, decided once.
  /// Null where there is none — under `flutter test` the executable is the
  /// tester, and a build whose last phase did not run has no helper.
  static final String? bundle = () {
    final executable = Platform.resolvedExecutable;
    final at = executable.indexOf(".app/Contents/MacOS/");
    if (at < 0) return null;
    final helper = p.join(
      executable.substring(0, at + 4),
      "Contents",
      "Helpers",
      "Entoli Models.app",
    );
    return Directory(helper).existsSync() ? helper : null;
  }();

  /// Whether there is a [bundle] to [launch]; the composition root asks,
  /// once, and runs the models in its own process where there is not.
  static bool get canLaunch => bundle != null;

  static Future<HostConnection> launch() async {
    assert(canLaunch, "No model host bundle to start.");
    final dir = await Directory.systemTemp.createTemp("entoli-models-");
    final path = p.join(dir.path, "s");
    final key = randomToken(24);
    final server = await ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    try {
      // An app of its own rather than a child, so its GPU work is not
      // scheduled as this app's; its parent is launchd, so it watches [pid]
      // for this app going. The key rides in its environment, which nothing
      // else can read.
      try {
        await _launcher.invokeMethod("open", {
          "arguments": ["entoli-models", path, "$pid"],
          // The app's own beside it: what LaunchServices is handed is the
          // whole of the host's environment, not an addition to one.
          "environment": {...Platform.environment, modelHostKeyVariable: key},
        });
      } on PlatformException catch (e) {
        throw StateError("The model host would not open: ${e.message}");
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
}
