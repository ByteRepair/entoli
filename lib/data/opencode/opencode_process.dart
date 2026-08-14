// Spawns and manages a per-chat `opencode serve` process on the desktop.
// Started lazily with the chat's workspace as working directory so that
// sessions created via POST /session inherit that cwd. Stopped on dispose.
import "dart:async";
import "dart:io";

class OpencodeProcess {
  OpencodeProcess._({
    required this.url,
    required this.process,
    required this.workspacePath,
  });

  final Uri url;
  final Process process;
  final String workspacePath;

  /// Start a per-chat server with [workingDirectory] as the workspace.
  /// [processFactory] is injectable for tests.
  static Future<OpencodeProcess> start({
    required String workingDirectory,
    String? binary,
    String? password,
    ProcessFactory? processFactory,
  }) async {
    final bin = binary ?? Platform.environment["OPENCODE_BINARY"] ?? "opencode";
    final port = await _pickFreePort();

    final args = <String>[
      "serve",
      "--port",
      port.toString(),
      "--hostname",
      "127.0.0.1",
    ];

    final env = <String, String>{};
    if (password != null) env["OPENCODE_SERVER_PASSWORD"] = password;

    final factory = processFactory ?? _DefaultProcessFactory();
    final process = await factory.start(
      bin,
      args,
      workingDirectory: workingDirectory,
      environment: env,
    );

    final url = Uri.parse("http://127.0.0.1:$port");
    await _waitForHealth(url, password);

    return OpencodeProcess._(
      url: url,
      process: process,
      workspacePath: workingDirectory,
    );
  }

  /// Stop this server.
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

  static Future<void> _waitForHealth(Uri url, String? password) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final client = HttpClient();
        final req = await client.getUrl(url.resolve("/global/health"));
        final resp = await req.close().timeout(const Duration(seconds: 2));
        if (resp.statusCode == 200) {
          client.close();
          return;
        }
        client.close();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 200));
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