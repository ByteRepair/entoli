import "../../../domain/shell.dart";

Shell platformShell({required Map<String, String> Function() environment}) =>
    const UnavailableShell();

String? processEnv(String name) => null;
