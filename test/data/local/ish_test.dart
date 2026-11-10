import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/domain/shell.dart";

/// What can be pinned on a machine with no iOS on it: the shared dispatcher
/// script (the wire protocol both LocalShell and IshShell run) and the FFI
/// bridge's names against the link and the C source.
void main() {
  group("the dispatcher script", () {
    test(
      "carries the token so a command's output cannot forge the end of a run",
      () {
        final script = dispatcherScript("abc123");
        expect(script, contains("@@Eabc123"));
      },
    );
  });

  group("the FFI bridge", () {
    // A release link dead-strips any bridge function nothing calls, and Dart
    // calls them by name only, so each looked-up name has to be on
    // Ish.xcconfig's ISH_KEEP_NAMES. A name missing there links in debug and
    // throws on the first shell of a TestFlight build, which no simulator run
    // shows.
    test("keeps every name ish_ffi.dart looks up, and only those", () {
      final keepLine = File(
        "ios/Flutter/Ish.xcconfig",
      ).readAsLinesSync().singleWhere((l) => l.startsWith("ISH_KEEP_NAMES ="));
      final kept = RegExp(
        r"-Wl,-u,_((?:ish|blinkish)_[a-z_]+)",
      ).allMatches(keepLine).map((m) => m[1]!).toSet();
      final looked = _lookedUp();
      expect(looked, isNotEmpty);
      expect(kept, looked);
    });

    // A definition, not a mention: a return type at the start of a line, the
    // name, and a body that opens before any semicolon could end a prototype
    // or a call.
    test("every looked-up name is a function the bridge defines", () {
      final bridge = File("tool/ios/ish/ish_bridge.c").readAsStringSync();
      for (final name in _lookedUp()) {
        final definedName = name.startsWith("blinkish_")
            ? "ish_${name.substring("blinkish_".length)}"
            : name;
        final head = RegExp(
          "^[A-Za-z_][\\w \\t*]*\\b$definedName\\s*\\(",
          multiLine: true,
        ).allMatches(bridge);
        final defined = head.any((m) {
          final rest = bridge.substring(m.end);
          final brace = rest.indexOf("{");
          final semi = rest.indexOf(";");
          return brace >= 0 && (semi < 0 || brace < semi);
        });
        expect(
          defined,
          isTrue,
          reason:
              "$name is looked up but ish_bridge.c defines no such function",
        );
      }
    });
  });
}

/// The names ish_ffi.dart hands to `lookupFunction` — the lookups themselves,
/// not every quoted `ish_` string the file may come to hold. A bridge's are
/// written once over its core's prefix, so they are every core's prefix
/// with every one of those, beside the lookups named outright.
Set<String> _lookedUp() {
  final source = File("lib/data/local/ish_ffi.dart").readAsStringSync();
  final prefixes = RegExp(
    r'^\s*\w+\("((?:ish|blinkish))"\)[,;]$',
    multiLine: true,
  ).allMatches(source).map((m) => m[1]!);
  final perCore = RegExp(
    r'lookupFunction<[^>]*>\(\s*"\$\{prefix\}_([a-z_]+)"',
  ).allMatches(source).map((m) => m[1]!);
  final outright = RegExp(
    r'lookupFunction<[^>]*>\(\s*"((?:ish|blinkish)_[a-z_]+)"',
  ).allMatches(source).map((m) => m[1]!);
  return {
    for (final prefix in prefixes)
      for (final name in perCore) "${prefix}_$name",
    ...outright,
  };
}
