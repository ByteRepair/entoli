import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

import "workspace_packages.dart";

/// Every source under the app's and the packages' `lib/`s by path, as text.
final _texts = {
  for (final dir in [
    "lib",
    for (final package in Directory("packages").listSync())
      if (Directory(p.join(package.path, "lib")).existsSync())
        p.join(package.path, "lib"),
  ])
    for (final file in dartSources(dir)) file.path: file.readAsStringSync(),
};

/// The providers declared under [dir] with no value of their own: a port
/// whoever assembles a front end binds.
Set<String> _ports(String dir) {
  final declaration = RegExp(
    r"final (\w+)\s*=[^;]*?\(ref\)\s*=>\s*throw UnimplementedError\(",
  );
  return {
    for (final MapEntry(key: file, value: text) in _texts.entries)
      if (p.isWithin(dir, file))
        for (final m in declaration.allMatches(text)) m.group(1)!,
  };
}

/// Every `final name = <Override>[...]` list in the roots, by name, so a
/// spread in a composition reads as what it spreads.
final _lists = {
  for (final text in _texts.values)
    for (final m in RegExp(
      r"final (\w+) = <Override>\[(.*?)\n\];",
      dotAll: true,
    ).allMatches(text))
      m.group(1)!: m.group(2)!,
};

/// [file]'s text with every override list it spreads written out.
String _composition(String file) {
  var text = File(file).readAsStringSync();
  final seen = <String>{};
  while (true) {
    final spreads = {
      for (final m in RegExp(r"\.\.\.(\w+)").allMatches(text))
        if (_lists.containsKey(m.group(1)) && seen.add(m.group(1)!))
          m.group(1)!,
    };
    if (spreads.isEmpty) return text;
    text = [text, for (final name in spreads) _lists[name]!].join("\n");
  }
}

void main() {
  final core = _ports(p.join("packages", "entoli_core", "lib"));
  final app = _ports("lib");

  List<String> unbound(Set<String> ports, String file) {
    final text = _composition(file);
    return [
      for (final port in ports)
        if (!text.contains("$port.overrideWith")) port,
    ]..sort();
  }

  test("the core declares ports for its front ends to bind", () {
    expect(core, isNotEmpty);
  });

  test("the app's main binds every port", () {
    expect(unbound({...core, ...app}, p.join("lib", "main.dart")), isEmpty);
  });

  test("the test harness binds every port the core declares", () {
    expect(unbound(core, p.join("test", "harness.dart")), isEmpty);
  });

  test("the viewer's main binds every port the core declares", () {
    expect(
      unbound(
        core,
        p.join("packages", "entoli_share_viewer", "lib", "main.dart"),
      ),
      isEmpty,
    );
  });
}
