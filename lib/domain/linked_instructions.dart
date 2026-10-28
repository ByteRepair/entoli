/// Instruction files the user linked from elsewhere on a desktop — a
/// CLAUDE.md, another repo's AGENTS.md — read after the global AGENTS.md in
/// [files]' order, and the global files each project switched off. Every
/// file is on in every project until a project says otherwise, so only the
/// exceptions are kept, and a file linked later reaches every project.
class LinkedInstructions {
  const LinkedInstructions({this.files = const [], this.off = const {}});

  final List<String> files;

  /// Project name to the paths it switched off. The global AGENTS.md can be
  /// among them, under its own path, beside the linked ones.
  final Map<String, List<String>> off;

  bool isOn(String? project, String path) =>
      project == null || !(off[project]?.contains(path) ?? false);

  /// The user's files [project]'s turns read, in reading order: [global]
  /// first, then the linked ones.
  List<String> filesFor(String? project, String global) => [
        for (final path in [global, ...files])
          if (isOn(project, path)) path,
      ];

  /// [files] replaced. A path no longer linked loses its switches, other than
  /// [keep]'s, so linking it again starts it on everywhere.
  LinkedInstructions withFiles(List<String> files, {required String keep}) {
    final linked = {...files, keep};
    return LinkedInstructions(
      files: files,
      off: {
        for (final e in off.entries)
          e.key: e.value.where(linked.contains).toList(),
      }..removeWhere((_, paths) => paths.isEmpty),
    );
  }

  /// [project]'s switched-off [paths] replaced.
  LinkedInstructions withOff(String project, Iterable<String> paths) =>
      LinkedInstructions(files: files, off: {
        ...off,
        project: paths.toList(),
      }..removeWhere((_, paths) => paths.isEmpty));

  LinkedInstructions withoutProject(String project) => off.containsKey(project)
      ? LinkedInstructions(files: files, off: {...off}..remove(project))
      : this;

  factory LinkedInstructions.fromJson(Map<String, dynamic> json) =>
      LinkedInstructions(
        files: [
          for (final f in json["files"] as List<dynamic>? ?? const [])
            if (f is String) f,
        ],
        off: {
          for (final MapEntry(:key, :value)
              in (json["off"] as Map<String, dynamic>? ?? const {}).entries)
            if (value is List) key: [for (final p in value) if (p is String) p],
        },
      );

  Map<String, dynamic> toJson() => {"files": files, "off": off};
}
