// Validating a SKILL.md against the Agent Skills spec, so a non-conformant
// skill is refused at import and at `create_skill`, skipped at load, and
// explained on the skill view page — rather than loaded and rendered oddly.
//
// Entoli's per-client keys (`argument-hint`, `user-invocable`,
// `disable-model-invocation`) live under the spec's `metadata:` map, which is
// the spec's own extension point, so conforming skills carry them and nothing
// here reads a key the spec does not name.
import "../../domain/frontmatter.dart";

/// The frontmatter keys the Agent Skills spec names, which is also the whole
/// whitelist: any other top-level key is a problem.
const skillSpecKeys = {
  "name",
  "description",
  "license",
  "compatibility",
  "metadata",
  "allowed-tools",
};

/// Why a SKILL.md does not conform. One problem per line, worded for a person
/// — the import refusal joins them, the view page shows them one to a line.
/// [name] is the name the skill would carry (frontmatter's, else [folderName]'s
/// — the same rule the loader applies); [folderName] is the directory it sits
/// in, where it has one, since the spec requires the two to match.
List<String> skillProblems({
  required String name,
  required String? description,
  required Map<String, String> frontmatter,
  String? folderName,
}) {
  final problems = [..._nameProblems(name)];
  if (description == null || description.trim().isEmpty) {
    problems.add("no description in the SKILL.md frontmatter");
  } else if (description.length > 1024) {
    problems.add("description is ${description.length} characters (max 1024)");
  }
  final allowed = skillSpecKeys.toList()..sort();
  for (final key in frontmatter.keys) {
    if (skillSpecKeys.contains(key)) continue;
    problems.add("unknown frontmatter key \"$key\" (allowed: ${allowed.join(", ")})");
  }
  final compatibility = frontmatter["compatibility"];
  if (compatibility != null && compatibility.length > 500) {
    problems.add(
        "compatibility is ${compatibility.length} characters (max 500)");
  }
  if (folderName != null && name != folderName) {
    problems.add(
        "frontmatter name \"$name\" does not match the folder \"$folderName\"");
  }
  return problems;
}

/// The spec's `name` rule: 1-64 characters, lowercase letters, digits and
/// hyphens, no leading/trailing/consecutive hyphen.
bool skillNameOk(String name) =>
    name.isNotEmpty &&
    name.length <= 64 &&
    RegExp(r"^[a-z0-9]+(-[a-z0-9]+)*$").hasMatch(name);

List<String> _nameProblems(String name) {
  if (name.isEmpty) {
    return ["no name — not in the frontmatter and the folder is not named "
        "either"];
  }
  if (name.length > 64) {
    return ["name is ${name.length} characters (max 64)"];
  }
  if (!skillNameOk(name)) {
    return ["name \"$name\" is not lowercase letters, digits and hyphens "
        "with no doubled or leading/trailing hyphen"];
  }
  return const [];
}

/// The problems of the frontmatter a skill's SKILL.md parsed to, against the
/// folder it would be served from — the whole validation, runnable wherever a
/// [Frontmatter] is already in hand (loader, import, generators).
List<String> skillFrontmatterProblems(
        Frontmatter parsed, String folderName) =>
    skillProblems(
      name: parsed.name ?? folderName,
      description: parsed.description,
      frontmatter: parsed.scalars,
      folderName: folderName,
    );