import "dart:convert";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;
import "package:yaml/yaml.dart";

/// Every package the workspace resolved, by name, as its pubspec.
Map<String, YamlMap> _pubspecs() {
  final config = File(p.join(".dart_tool", "package_config.json"));
  final base = Uri.directory(p.absolute(".dart_tool"));
  final packages =
      (jsonDecode(config.readAsStringSync()) as Map)["packages"] as List;
  return {
    for (final package in packages.cast<Map>())
      if (File(base.resolve("${package["rootUri"]}/pubspec.yaml").toFilePath())
          case final pubspec when pubspec.existsSync())
        package["name"] as String:
            loadYaml(pubspec.readAsStringSync()) as YamlMap,
  };
}

/// What [pubspec] depends on to run: not its dev dependencies, which no
/// build of it carries.
Set<String> _dependencies(YamlMap pubspec) => {
  ...?(pubspec["dependencies"] as YamlMap?)?.keys.cast<String>(),
};

/// A Flutter plugin is a package whose pubspec says it is one.
bool _isPlugin(YamlMap pubspec) => switch (pubspec["flutter"]) {
  final YamlMap flutter => flutter.containsKey("plugin"),
  _ => false,
};

/// The adapters: every `packages/entoli_*` but the core and the viewer.
final _adapters = {
  for (final dir in Directory("packages").listSync().whereType<Directory>())
    if (p.basename(dir.path) case final name
        when name.startsWith("entoli_") &&
            name != "entoli_core" &&
            name != "entoli_share_viewer")
      name,
};

void main() {
  final pubspecs = _pubspecs();

  /// Each plugin reachable from [from] without passing through [skip], as
  /// the path to it: `agent_chat -> url_launcher`.
  List<String> pluginsFrom(String from, {Set<String> skip = const {}}) {
    final via = <String, String>{from: from};
    final queue = [from];
    final found = <String>[];
    while (queue.isNotEmpty) {
      final name = queue.removeAt(0);
      final pubspec = pubspecs[name];
      if (pubspec == null) fail("$name is not in package_config.json");
      if (name != from && _isPlugin(pubspec)) found.add(via[name]!);
      for (final dep in _dependencies(pubspec)) {
        if (skip.contains(dep) || via.containsKey(dep)) continue;
        via[dep] = "${via[name]} -> $dep";
        queue.add(dep);
      }
    }
    return found;
  }

  // The viewer runs the core in a browser, so a plugin in it is one more
  // thing the web has to build; see "The core" in AGENTS.md.
  test("the core reaches no Flutter plugin", () {
    expect(pluginsFrom("entoli_core"), isEmpty);
  });

  // A front end names the core and the adapters it chose, and its plugins
  // arrive through those: take its adapters out of the graph and none is
  // left.
  for (final frontEnd in ["agent_chat", "entoli_share_viewer"]) {
    final chosen = _dependencies(pubspecs[frontEnd]!).intersection(_adapters);

    test("$frontEnd depends on no plugin but an adapter", () {
      expect([
        for (final dep in _dependencies(pubspecs[frontEnd]!))
          if (!_adapters.contains(dep) && _isPlugin(pubspecs[dep]!))
            "$frontEnd -> $dep",
      ], isEmpty);
    });

    test("$frontEnd reaches every plugin through an adapter it chose", () {
      expect(pluginsFrom(frontEnd, skip: chosen), isEmpty);
    });
  }

  test("each adapter depends on the core and on no front end", () {
    expect(_adapters, isNotEmpty);
    expect([
      for (final adapter in _adapters)
        if (_dependencies(pubspecs[adapter]!) case final deps)
          if (!deps.contains("entoli_core"))
            "$adapter does not depend on entoli_core"
          else
            for (final frontEnd in ["agent_chat", "entoli_share_viewer"])
              if (deps.contains(frontEnd)) "$adapter -> $frontEnd",
    ], isEmpty);
  });
}
