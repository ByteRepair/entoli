import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

/// The app's `lib/` and the chat package's, each under its package name. The
/// two are one layout split in two, so a layer is a layer in either.
final _roots = {
  "agent_chat": p.normalize(p.absolute("lib")),
  "entoli_core": p.normalize(p.absolute("packages", "entoli_core", "lib")),
};

/// [file] from the `lib/` it is in, so `model/models.dart` in either.
String _relative(String file) => p.relative(
  file,
  from: _roots.values.firstWhere((root) => p.isWithin(root, file)),
);

/// Both `lib/`s' files and what each imports or exports of the others, every
/// branch of a conditional one included.
Map<String, Set<String>> _graph() {
  final directive = RegExp(r"^(?:import|export)\s[^;]*;", multiLine: true);
  final uri = RegExp(r'"([^"]+\.dart)"');
  final graph = <String, Set<String>>{};
  for (final lib in _roots.values) {
    for (final file in Directory(
      lib,
    ).listSync(recursive: true).whereType<File>()) {
      final path = file.path;
      if (!path.endsWith(".dart") ||
          path.endsWith(".g.dart") ||
          path.endsWith(".freezed.dart")) {
        continue;
      }
      final edges = graph[path] = {};
      for (final match in directive.allMatches(file.readAsStringSync())) {
        for (final target in uri.allMatches(match.group(0)!)) {
          final name = target.group(1)!;
          final package = _roots.entries
              .where((root) => name.startsWith("package:${root.key}/"))
              .firstOrNull;
          if (package != null) {
            edges.add(
              p.join(
                package.value,
                name.substring("package:${package.key}/".length),
              ),
            );
          } else if (!name.contains(":")) {
            edges.add(p.normalize(p.join(p.dirname(path), name)));
          }
        }
      }
    }
  }
  return graph;
}

/// The groups of files that reach each other through their imports, by
/// Tarjan's strongly connected components; a file alone is not a group.
List<List<String>> _cycles(Map<String, Set<String>> graph) {
  final index = <String, int>{};
  final low = <String, int>{};
  final stack = <String>[];
  final onStack = <String>{};
  final groups = <List<String>>[];
  var next = 0;
  void visit(String v) {
    index[v] = low[v] = next++;
    stack.add(v);
    onStack.add(v);
    for (final w in graph[v]!) {
      if (!graph.containsKey(w)) continue;
      if (!index.containsKey(w)) {
        visit(w);
        low[v] = low[v]! < low[w]! ? low[v]! : low[w]!;
      } else if (onStack.contains(w)) {
        low[v] = low[v]! < index[w]! ? low[v]! : index[w]!;
      }
    }
    if (low[v] != index[v]) return;
    final group = <String>[];
    String w;
    do {
      w = stack.removeLast();
      onStack.remove(w);
      group.add(w);
    } while (w != v);
    if (group.length > 1) groups.add(group..sort());
  }

  for (final v in graph.keys) {
    if (!index.containsKey(v)) visit(v);
  }
  return groups;
}

void main() {
  // A cycle is a file that is both something others build on and a user of
  // those builders: a base beside its catalogue, a page beside the state other
  // pages read. Split the abstraction from the concrete and bind them at the
  // top; see "Imports point one way" in AGENTS.md.
  test("no file in lib/ reaches itself through its imports", () {
    final graph = _graph();
    expect(graph, isNotEmpty);
    expect([
      for (final group in _cycles(graph)) [for (final f in group) _relative(f)],
    ], isEmpty);
  });

  // In the core, `model/` is the terms, `store/` the disk under them and
  // `transcript/` what `view/` draws. In the app, `data/` runs without knowing
  // how it is drawn and `app/` is what `ui/` renders; `core/` and `main.dart`
  // assemble it and may reach anything.
  const above = {
    "agent_chat": {
      "data": {"app", "ui"},
      "app": {"ui"},
    },
    "entoli_core": {
      "model": {"store", "transcript", "view"},
      "store": {"transcript", "view"},
      "transcript": {"view"},
    },
  };
  String? packageOf(String file) =>
      _roots.entries.where((e) => p.isWithin(e.value, file)).firstOrNull?.key;

  test("each layer imports nothing of the layers above it", () {
    String layer(String file) => p.split(_relative(file)).first;
    expect([
      for (final MapEntry(key: file, value: imports) in _graph().entries)
        for (final target in imports)
          if (packageOf(file) == packageOf(target) &&
              (above[packageOf(file)]?[layer(file)]?.contains(layer(target)) ??
                  false))
            "${_relative(file)} -> ${_relative(target)}",
    ], isEmpty);
  });

  // The graph above sees only the app's own files, so a widget library is
  // checked by name. `foundation` is the listenables a model is made of.
  test(
    "the app's core and the transcript import no Flutter but foundation",
    () {
      final flutter = RegExp(
        r'^(?:import|export)\s+"package:flutter/(\w+)\.dart"',
        multiLine: true,
      );
      expect([
        for (final dir in [
          p.join(_roots["agent_chat"]!, "app"),
          p.join(_roots["entoli_core"]!, "transcript"),
        ])
          for (final file in Directory(
            dir,
          ).listSync(recursive: true).whereType<File>())
            if (file.path.endsWith(".dart"))
              for (final m in flutter.allMatches(file.readAsStringSync()))
                if (m.group(1) != "foundation")
                  "${_relative(file.path)} -> flutter/${m.group(1)}",
      ], isEmpty);
    },
  );

  // The share viewer runs the core without the app, which is what
  // keeps voice and the native plugins out of it.
  test("the core imports nothing of the app", () {
    final graph = _graph();
    final app = _roots["agent_chat"]!;
    final chat = _roots["entoli_core"]!;
    expect([
      for (final MapEntry(key: file, value: imports) in graph.entries)
        if (p.isWithin(chat, file))
          for (final target in imports)
            if (p.isWithin(app, target)) "${_relative(file)} -> $target",
    ], isEmpty);
  });

  test("the check finds a cycle where there is one", () {
    expect(
      _cycles({
        "a": {"b"},
        "b": {"c"},
        "c": {"a"},
        "d": {"a"},
      }),
      [
        ["a", "b", "c"],
      ],
    );
  });
}
