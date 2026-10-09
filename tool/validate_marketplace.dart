// Marketplace validation, run by CI as the single source of truth: one
// entry's rules live here and nowhere else, and they are the same ones the
// app applies — skill problems come from `skill_validate.dart`, which the
// loader, the importer and `create_skill` all share.
//
//   dart tool/validate_marketplace.dart [--data-root data] [--changed FILE]
//
// With --changed, only entries a `git diff --name-status -M` output touches
// are validated (full removals are allowed; partial ones fail the file
// checks); without it, every directory under <data-root>/{skills,agents}.
import "dart:io";

import "package:agent_chat/data/prompts/skill_validate.dart";
import "package:agent_chat/domain/frontmatter.dart";

final _semverRe = RegExp(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(-((0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)"
    r"(\.(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?"
    r"(\+([0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)*))?$");

const _agentAllowedFiles = {"README.md", "PROMPT.md", "profile.png"};
const _requiredFiles = {
  "skills": ["README.md", "SKILL.md"],
  "agents": ["README.md", "PROMPT.md"],
};

void main(List<String> args) {
  var dataRoot = "data";
  String? changedFile;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "--data-root":
        dataRoot = args[++i];
      case "--changed":
        changedFile = args[++i];
      default:
        stderr.writeln("unknown argument ${args[i]}");
        exit(2);
    }
  }

  final problems = <String>[];
  var checked = 0;
  final touched = changedFile == null
      ? {
          "skills": _discoverSlugs(dataRoot, "skills"),
          "agents": _discoverSlugs(dataRoot, "agents"),
        }
      : _slugsFromDiff(File(changedFile).readAsStringSync(), dataRoot);
  for (final entry in touched.entries) {
    for (final slug in entry.value) {
      checked++;
      problems.addAll(_validateEntry(dataRoot, entry.key, slug));
    }
  }
  problems.addAll(_sectionProblems(dataRoot, touched.keys));

  if (problems.isNotEmpty) {
    stderr
      ..writeln("validation failed with ${problems.length} problem(s):")
      ..writeAll(problems.map((p) => "  $p\n"));
    exit(1);
  }
  stdout.writeln("OK: $checked checked");
}

Map<String, Set<String>> _slugsFromDiff(String diff, String dataRoot) {
  final touched = <String, Set<String>>{};
  final kept = <String, Set<String>>{};
  (String, String)? mapPath(String path) {
    final rest = path.split("/");
    // data/<section>/<slug>/rest — shorter paths are not entry content.
    return rest.length < 3 || rest[0] != "data"
        ? null
        : (rest[1], rest[2]);
  }

  for (final line in diff.split("\n")) {
    final parts = line.split("\t");
    if (parts.isEmpty || parts.first.isEmpty) continue;
    final status = parts.first.substring(0, 1);
    if (status == "D") {
      final mapped = mapPath(parts[1]);
      if (mapped != null) kept.putIfAbsent(mapped.$1, () => {}).add(mapped.$2);
      continue;
    }
    final mapped = mapPath(parts.last);
    if (mapped != null) {
      touched.putIfAbsent(mapped.$1, () => {}).add(mapped.$2);
    }
    if ((status == "R" || status == "C") && parts.length > 2) {
      final old = mapPath(parts[1]);
      if (old != null) kept.putIfAbsent(old.$1, () => {}).add(old.$2);
    }
  }
  return _dropFullyRemoved(touched, kept, dataRoot);
}

Map<String, Set<String>> _dropFullyRemoved(Map<String, Set<String>> touched,
    Map<String, Set<String>> kept, String dataRoot) {
  final result = <String, Set<String>>{};
  for (final section in ["skills", "agents"]) {
    final slugs = touched[section] ?? {};
    for (final slug in (kept[section] ?? {})) {
      if (Directory("$dataRoot/$section/$slug").existsSync()) slugs.add(slug);
    }
    result[section] = slugs;
  }
  return result;
}

Set<String> _discoverSlugs(String dataRoot, String section) {
  final dir = Directory("$dataRoot/$section");
  if (!dir.existsSync()) return {};
  return dir
      .listSync()
      .whereType<Directory>()
      .map(_basename)
      .toSet();
}

List<String> _validateEntry(String dataRoot, String section, String slug) {
  final problems = <String>[];
  final base = "$dataRoot/$section/$slug";
  final path = "$base/${section == "skills" ? "SKILL.md" : "PROMPT.md"}";

  if (!skillNameOk(slug)) {
    problems.add("$base: slug is not lowercase kebab-case");
  }
  for (final required in _requiredFiles[section]!) {
    if (!File("$base/$required").existsSync()) {
      problems.add("$base/$required: missing required file");
    }
  }
  final file = File(path);
  if (file.existsSync()) {
    problems.addAll(_validateDocument(
      section: section,
      slug: slug,
      source: file.readAsStringSync(),
      path: path,
    ));
  }
  if (section == "agents") {
    final png = File("$base/profile.png");
    if (png.existsSync() &&
        !_isPng(png.openSync().readSync(_pngMagic.length))) {
      problems.add("$base/profile.png: not a PNG file");
    }
    for (final extra in Directory(base).listSync()) {
      if (!_agentAllowedFiles.contains(_basename(extra))) {
        problems.add("$extra: not part of the agent schema");
      }
    }
  }
  return problems;
}

String _basename(FileSystemEntity entity) =>
    entity.uri.pathSegments.where((s) => s.isNotEmpty).last;

List<String> _validateDocument({
  required String section,
  required String slug,
  required String source,
  required String path,
}) {
  final problems = <String>[];
  final parsed = Frontmatter.parse(source);
  if (parsed.scalars.isEmpty && parsed.metadata.isEmpty) {
    if (!source.startsWith("---")) {
      return ["$path: no frontmatter block"];
    }
    return ["$path: frontmatter block did not parse as a YAML map"];
  }

  if (section == "skills") {
    // skillFrontmatterProblems validates the frontmatter name (or its folder
    // fallback) against the slug and the spec caps; only the missing-name
    // rule is added here, which the shared validator masks by that fallback.
    problems.addAll(skillFrontmatterProblems(parsed, slug).map((p) => "$path: $p"));
    if (parsed.name == null) problems.add("$path: missing 'name' in the frontmatter");
  } else {
    for (final key in parsed.scalars.keys) {
      if (key == "description" || key == "metadata") continue;
      if (key == "name") {
        problems.add("$path: an agent's name is its file name; no 'name' key");
      } else {
        problems.add(
            "$path: unexpected frontmatter key \"$key\" (an agent carries only "
            "description and metadata)");
      }
    }
    if (parsed.description == null || parsed.description!.trim().isEmpty) {
      problems.add("$path: no description in the frontmatter");
    }
  }

  final metadata = parsed.metadata;
  final author = metadata["author"];
  if (author == null || author.trim().isEmpty) {
    problems.add("$path: metadata carries no usable 'author'");
  }
  final version = metadata["version"];
  if (version != null && !_semverRe.hasMatch(version)) {
    problems.add("$path: metadata 'version' must be a SemVer string (got \"$version\")");
  }
  final tags = metadata["tags"];
  if (tags != null) {
    final parts = tags.split(",").map((t) => t.trim()).where((t) => t.isNotEmpty);
    if (tags.trim().startsWith("[") || tags.trim().endsWith("]")) {
      problems.add('$path: metadata "tags" must be a comma-separated string, not a list');
    } else if (parts.toSet().length != parts.length) {
      problems.add("$path: metadata 'tags' contains duplicates");
    }
  }
  return problems;
}

/// Sections are checked once, not per entry: a file sitting directly under
/// data/skills/ or data/agents/ is not an entry and belongs to nothing.
List<String> _sectionProblems(String dataRoot, Iterable<String> sections) {
  final problems = <String>[];
  for (final section in sections) {
    final dir = Directory("$dataRoot/$section");
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      problems.add("$entity: file at the section root, not inside an entry");
    }
  }
  return problems;
}

const _pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

bool _isPng(List<int> bytes) {
  if (bytes.length < _pngMagic.length) return false;
  for (var i = 0; i < _pngMagic.length; i++) {
    if (bytes[i] != _pngMagic[i]) return false;
  }
  return true;
}