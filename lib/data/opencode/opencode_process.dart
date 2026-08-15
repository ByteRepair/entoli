// Spawns and manages a per-chat `opencode serve` process on the desktop.
// Started lazily with the chat's workspace as working directory so that
// sessions created via POST /session inherit that cwd. Stopped on dispose.
import "dart:async";
import "dart:io";

import "opencode_client.dart";

class OpencodeProcess {
  OpencodeProcess._({required this.url, required this.process});

  final Uri url;
  final Process process;

  /// Start a per-chat server with [workingDirectory] as the workspace.
  /// [processFactory] is injectable for tests.
  static Future<OpencodeProcess> start({
    required String workingDirectory,
    String? binary,
    String? password,
    ProcessFactory? processFactory,
    Map<String, String> environment = const {},
  }) async {
    final bin = binary ?? Platform.environment["OPENCODE_BINARY"] ?? "opencode";
    // The port is probed, released, then claimed by the server, so another
    // process can take it in between. Losing that race looks like a health
    // timeout, so try again on a different port rather than failing the chat.
    for (var attempt = 0;; attempt++) {
      try {
        return await _startOn(
            await _pickFreePort(), bin, password, workingDirectory, processFactory, environment);
      } on TimeoutException {
        if (attempt >= 2) rethrow;
      }
    }
  }

  static Future<OpencodeProcess> _startOn(
    int port,
    String bin,
    String? password,
    String workingDirectory,
    ProcessFactory? processFactory,
    Map<String, String> environment,
  ) async {
    final args = <String>[
      "serve",
      "--port",
      port.toString(),
      "--hostname",
      "127.0.0.1",
    ];

    final factory = processFactory ?? _DefaultProcessFactory();
    final process = await factory.start(
      bin,
      args,
      workingDirectory: workingDirectory,
      environment: {...environment, "OPENCODE_SERVER_PASSWORD": ?password},
    );

    final url = Uri.parse("http://127.0.0.1:$port");
    try {
      await _waitForHealth(url, password);
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
      rethrow;
    }

    return OpencodeProcess._(url: url, process: process);
  }

  Future<void> stop() async {
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    });
  }

  static Future<int> _pickFreePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }

  /// Poll until the server answers. Uses the same client as everything else,
  /// so auth stays in one place.
  static Future<void> _waitForHealth(Uri url, String? password) async {
    final client = OpencodeClient(baseUrl: url, password: password);
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    try {
      while (DateTime.now().isBefore(deadline)) {
        try {
          await client.health().timeout(const Duration(seconds: 2));
          return;
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 200));
      }
    } finally {
      await client.close();
    }
    throw TimeoutException("opencode server did not become healthy within 15s");
  }
}

/// Injectable factory for spawning processes. Tests provide a fake.
abstract class ProcessFactory {
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  });
}

class _DefaultProcessFactory implements ProcessFactory {
  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
  }
}