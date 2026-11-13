import "settings/keys.dart";
import "settings/setting.dart";

/// The folders a sandboxed command may write beside the workspaces without
/// anyone granting them: what ordinary tools write in passing, where a
/// refusal only ever sent the agent out of the sandbox altogether. Each is
/// on unless the user turns it off, at the default project or a project,
/// and is drawn as its own toggle rather than as a work folder. See
/// "Approvals" in `lib/data/builtin/AGENTS.md`.
enum SandboxGrant {
  systemTemps(
    "System temp folders",
    "/tmp and your user's temp folder, for tools that ignore TMPDIR.",
  ),
  caches(
    "Package and build caches",
    "~/.cache, ~/.npm, ~/.pub-cache, Cargo, Gradle, Xcode's DerivedData and "
        "the like.",
  ),
  toolchains(
    "Language toolchains",
    "Where uv keeps the Pythons it downloads and rustup its toolchains. "
        "Nothing on your PATH.",
  ),
  git(
    "Git repositories",
    "The .git folder of a repository a command works in, so a commit lands. "
        "Auto mode asks before a command changes its hooks or config.",
  );

  const SandboxGrant(this.title, this.description);

  final String title;
  final String description;

  Setting<bool> get setting => switch (this) {
    systemTemps => SettingKeys.sandboxTemps,
    caches => SettingKeys.sandboxCaches,
    toolchains => SettingKeys.sandboxToolchains,
    git => SettingKeys.sandboxGit,
  };

  /// The settings page's id for this grant's toggle.
  String get settingId => "sandbox.$name";
}
