// Shared by the prompt generators: walking assets/prompts/projects/ and
// emitting the embedded const lists they write. Run through gen_bundled_skills
// and gen_prompts, not on its own.
import "dart:convert";
import "dart:io";

import "package:agent_chat/domain/bundled_prompt_file.dart";
import "package:crypto/crypto.dart" as crypto;

/// The project directories under `assets/prompts/projects/`, sorted. `default`
/// is one of them, the way every project is one directory under `projects/`.
List<Directory> promptProjects() {
  final root = Directory("assets/prompts/projects");
  if (!root.existsSync()) return const [];
  return root.listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// The leaf of a path the walk composed with a literal `/` and the OS's own
/// separator both — the same string either way, so the leaf is split apart
/// from the last of the two.
String basename(String path) => path.split("/").last.split("\\").last;

List<String> allFiles(Directory dir) {
  final files = <String>[];
  for (final entity in dir.listSync()) {
    if (entity is Directory) {
      files.addAll(allFiles(entity));
    } else if (entity is File) {
      // The embedded const is one content whatever host generated it, and
      // the relative paths inside it are read everywhere; a backslash
      // generated here would not be a path on every other platform, and two
      // generators' checksums would drift over the same tree.
      files.add(entity.path.replaceAll("\\", "/"));
    }
  }
  return files;
}

String sha256Of(String content) =>
    crypto.sha256.convert(utf8.encode(content)).toString();

/// CRs read out to LF: a line ending is an accident of the checkout that
/// read the file, and the pair (sha256, content) a BundledPromptFile carries
/// must describe the same bytes whatever host collected them — the content
/// is embedded through stringLiteral, which reads the same way, so the hash
/// of a CR-bearing file would disagree with its own content and the
/// self-heal would rewrite it on every launch.
String normalizeCr(String s) =>
    s.replaceAll("\r\n", "\n").replaceAll("\r", "\n");

String sha256OfBytes(List<int> bytes) =>
    crypto.sha256.convert(bytes).toString();

void sortByProject(List<BundledPromptFile> entries) {
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
  stdout.writeln("Wrote $path");
}

/// Emits `const $varName = <BundledPromptFile>[ ... ]` from [entries],
/// each as `BundledPromptFile(project, name, relativePath, sha256, content)`.
/// A binary entry adds the flag and carries base64 — see the field's note.
void emitPromptFileList(
  StringBuffer buf,
  String varName,
  List<BundledPromptFile> entries,
) {
  buf.writeln("const $varName = <BundledPromptFile>[");
  for (final e in entries) {
    buf.writeln("  BundledPromptFile(");
    buf.writeln("      ${stringLiteral(e.project)},");
    buf.writeln("      ${stringLiteral(e.name)},");
    buf.writeln("      ${stringLiteral(e.relativePath)},");
    buf.writeln("      ${stringLiteral(e.sha256)},");
    if (e.binary) {
      buf.writeln("      ${stringLiteral(e.content)},");
      buf.writeln("      binary: true),");
    } else {
      buf.writeln("      ${stringLiteral(e.content)}),");
    }
  }
  buf.writeln("];");
  buf.writeln();
}

/// A Dart string literal, escaped and wrapped in double quotes. Triple-quote
/// is avoided: the content may contain both " and ', and a raw string cannot
/// escape. Every line is a separate concatenation so the diff stays readable.
/// `$` is escaped to `\$` so JavaScript template literals (`${item}`) in the
/// embedded content are not read as Dart interpolations. CRs are read out
/// first (normalizeCr), so one literal carries one line ending whatever ended
/// the file it came from — the generators' own reads normalize too, this
/// being the last place it still matters.
String stringLiteral(String s) {
  s = normalizeCr(s);
  final escaped = s
      .replaceAll("\\", "\\\\")
      .replaceAll('"', '\\"')
      .replaceAll("\$", r"\$")
      .replaceAll("\n", '\\n"\n      "');
  return '"$escaped"';
}
