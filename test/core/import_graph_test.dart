import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:path/path.dart" as p;

/// `lib/`'s files and what each imports or exports of the others, every
/// branch of a conditional one included.
Map<String, Set<String>> _graph() {
  final lib = p.normalize(p.absolute("lib"));
  final directive = RegExp(r"^(?:import|export)\s[^;]*;", multiLine: true);
  final uri = RegExp(r'"([^"]+\.dart)"');
  final graph = <String, Set<String>>{};
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
        if (name.startsWith("package:agent_chat/")) {
          edges.add(p.join(lib, name.substring("package:agent_chat/".length)));
        } else if (!name.contains(":")) {
          edges.add(p.normalize(p.join(p.dirname(path), name)));
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
    final lib = p.absolute("lib");
    expect([
      for (final group in _cycles(graph))
        [for (final file in group) p.relative(file, from: lib)],
    ], isEmpty);
  });

  // Between the layers, `domain/` is the app's own terms and knows nothing of
  // how it is stored or drawn, and `data/` stores and runs without knowing
  // how it is drawn. `core/` and `main.dart` assemble the app and may reach
  // anything.
  test("domain imports nothing of data or ui, and data nothing of ui", () {
    final lib = p.absolute("lib");
    const above = {
      "domain": {"data", "ui"},
      "data": {"ui"},
    };
    String layer(String file) => p.split(p.relative(file, from: lib)).first;
    expect([
      for (final MapEntry(key: file, value: imports) in _graph().entries)
        for (final target in imports)
          if (above[layer(file)]?.contains(layer(target)) ?? false)
            "${p.relative(file, from: lib)} -> ${p.relative(target, from: lib)}",
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
