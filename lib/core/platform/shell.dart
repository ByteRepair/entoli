import "../../domain/shell.dart";
import "io/shell.dart" if (dart.library.js_interop) "web/shell.dart" as platform;

/// Where the agent's commands run, and whether the process has an environment
/// to read a key out of. The whole of what varies by platform.
Shell platformShell({required Map<String, String> Function() environment}) =>
    platform.platformShell(environment: environment);

String? processEnv(String name) => platform.processEnv(name);
