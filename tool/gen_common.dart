// Shared by the prompt generators: walking assets/prompts/projects/ and
// emitting the embedded const lists they write. Run through gen_bundled_skills
// and gen_prompts, not on its own.
import "dart:convert";
import "dart:io";

import "package:crypto/crypto.dart" as crypto;

/// One embedded prompt file, tagged with the project it belongs to.
class PromptEntry {
  PromptEntry(this.project, this.name, this.relativePath, this.content);

  final String project;
  final String name;
  final String relativePath;
  final String content;

  String get sha256 => crypto.sha256.convert(utf8.encode(content)).toString();
}

/// The project directories under `assets/prompts/projects/`, sorted. `default`
/// is one of them, the way every project is one directory under `projects/`.
List<Directory> promptProjects() {
  final root = Directory("assets/prompts/projects");
  if (!root.existsSync()) return const [];
  return root.listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

String basename(String path) => path.split("/").last;

List<String> allFiles(Directory dir) {
  final files = <String>[];
  for (final entity in dir.listSync()) {
    if (entity is Directory) {
      files.addAll(allFiles(entity));
    } else if (entity is File) {
      files.add(entity.path);
    }
  }
  return files;
}

void sortByProject(List<PromptEntry> entries) {
  entries.sort((a, b) {
    final c = a.project.compareTo(b.project);
    if (c != 0) return c;
    final d = a.name.compareTo(b.name);
    if (d != 0) return d;
    return a.relativePath.compareTo(b.relativePath);
  });
}

void writeGenerated(String path, StringBuffer buf) {
  File(path).writeAsStringSync(buf.toString());
  stdout.writeln("Wrote $path (${buf.length} characters).");
}

/// Emits `const $varName = <BundledPromptFile>[ ... ]` from [entries],
/// each as `BundledPromptFile(project, name, relativePath, sha256, content)`.
void emitPromptFileList(StringBuffer buf, String varName,
    List<PromptEntry> entries) {
  buf.writeln("const $varName = <BundledPromptFile>[");
  for (final e in entries) {
    buf.writeln("  BundledPromptFile(");
    buf.writeln("      ${stringLiteral(e.project)},");
    buf.writeln("      ${stringLiteral(e.name)},");
    buf.writeln("      ${stringLiteral(e.relativePath)},");
    buf.writeln("      ${stringLiteral(e.sha256)},");
    buf.writeln("      ${stringLiteral(e.content)}),");
  }
  buf.writeln("];");
  buf.writeln();
}

/// A Dart string literal, escaped and wrapped in double quotes. Triple-quote
/// is avoided: the content may contain both " and ', and a raw string cannot
/// escape. Every line is a separate concatenation so the diff stays readable.
/// `$` is escaped to `\$` so JavaScript template literals (`${item}`) in the
/// embedded content are not read as Dart interpolations.
String stringLiteral(String s) {
  final escaped = s
      .replaceAll("\\", "\\\\")
      .replaceAll('"', '\\"')
      .replaceAll("\$", r"\$")
      .replaceAll("\n", '\\n"\n      "');
  return '"$escaped"';
}