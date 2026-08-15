import "dart:io";

import "../../../data/miniswe/local_shell.dart";
import "../../../domain/shell.dart";

Shell platformShell({required Map<String, String> Function() environment}) =>
    LocalShell(environment: environment);

String? processEnv(String name) => Platform.environment[name];
