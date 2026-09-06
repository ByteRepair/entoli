import "package:flutter/material.dart" show IconData;
import "package:path/path.dart" as p;

import "../core/config.dart";
import "builtin_project.dart";
import "project_settings.dart";

/// A project is a directory holding its own chats and a workspace they share.
/// It is named by that directory, so the name is what the agent sees in a path
/// and what the user types is made safe to be one.
///
/// `null` is the default project. It is a directory under `projects/` like any
/// other, and [defaultProjectDir] is its name; `null` rather than that string
/// everywhere above the filesystem, because which project is the default is not
/// a thing the UI or a stored setting should be able to disagree about.
///
/// A built-in project (`builtin_project.dart`) is a directory the same way,
/// except the app names it: [isProjectName] refuses its name so one cannot be
/// created, renamed or deleted, and [everyProject] is where it is offered.
const defaultProjectLabel = "Default";

/// The default project's directory, and so a name no other project may have.
const defaultProjectDir = "default";

String projectLabel(String? project) =>
    project == null ? defaultProjectLabel : builtinProjectOf(project)?.label ?? project;

/// The icon a project's badge or menu row shows beside its label, or null where
/// the project is a user's or the default — only a built-in ships one. Mirrors
/// [projectLabel] in resolving a built-in's shipped value.
IconData? projectIcon(String? project) => builtinProjectOf(project)?.icon;

/// The empty-chat screen's question when no built-in ships its own. A const
/// the way [defaultProjectLabel] is, so the screen and its tests name one
/// string.
const defaultEmptyChatQuestion = "What would you like to discuss?";

/// The question the empty-chat screen asks for a project: a built-in's own, or
/// the default. Mirrors [projectLabel] in resolving a built-in's shipped string.
String emptyChatQuestionFor(String? project) =>
    builtinProjectOf(project)?.emptyChatQuestion ?? defaultEmptyChatQuestion;

/// Every project there is, the default one first, then the built-in ones, then
/// the user's — the order the menus offer them in, and the order a chat is
/// looked for in.
List<String?> everyProject(List<String> named) =>
    [null, for (final builtIn in builtinProjects) builtIn.dir, ...named];

/// A stored project name read against the projects there are: one that has
/// since been deleted is the default project. A setting holds a name rather
/// than a reference, so both ends of one have to resolve it the same way, or a
/// field says `Default` while what it drives lands somewhere else. A built-in
/// name is always there — it cannot be deleted — so it resolves to itself
/// without asking [existing].
String? projectOrDefault(String? named, List<String> existing) =>
    named != null && (isBuiltinProject(named) || existing.contains(named))
        ? named
        : null;

/// One directory under `projects/` and nothing else: the shape a project
/// directory may have. The default project's and the built-in projects' names
/// have it too — a chat can be in one — so path construction accepts them;
/// what refuses them is [isProjectName]. Restated in Kotlin by
/// `WorkspaceProvider`, which cannot call this.
bool isProjectDirName(String name) =>
    name.isNotEmpty && !name.startsWith(".") && name == p.basename(name);

/// A name the user may create a project with: the directory shape, minus the
/// names the app ships — the default project's and the built-in projects'.
/// Those are named above the filesystem by `null` and by the app, so a second
/// way to name one would be a second entry for it in every list. Anything else
/// is a name that would reach outside `projects/`, and `projects/.hidden` is
/// not a project either.
bool isProjectName(String name) =>
    isProjectDirName(name) &&
    name.toLowerCase() != defaultProjectDir &&
    !isBuiltinProject(name);

/// Whether [project] has a project settings page worth opening. The default
/// project (`null`) has none; a built-in answers from its spec; a user's
/// project always does. The one answer the sidebar's settings gear reads,
/// regardless of project kind.
bool projectHasSettingsPage(String? project) {
  if (project == null) return false;
  final spec = builtinProjectOf(project);
  if (spec != null) return spec.hasSettingsPage;
  return isProjectName(project);
}

/// Whether Omada runs in [project]: a built-in's answer is its spec, a user
/// project's is the toggle in its `project.json`, and the default project's
/// is false — it has no settings page for one. Read through `Documents`'
/// in-memory copy, so a call is cheap enough for a menu row and a toggle
/// landing updates every surface that asked.
bool omadaOn(String? project, AppConfig config) {
  final spec = builtinProjectOf(project);
  if (spec != null) return spec.omada;
  if (project == null) return false;
  return ProjectSettings.load(config, project: project).omada;
}

/// The directory name for what the user typed, or null if nothing usable is
/// left of it. Deliberately strict: this ends up as a `cd` target in commands
/// the model writes.
String? projectNameFrom(String typed) {
  var name = typed.trim().replaceAll(RegExp(r"[^A-Za-z0-9._ -]"), "-");
  name = name.replaceAll(RegExp(r"\s+"), "-").replaceAll(RegExp(r"-{2,}"), "-");
  name = name.replaceAll(RegExp(r"^[.-]+|[.-]+$"), "");
  if (name.length > 64) name = name.substring(0, 64);
  return isProjectName(name) ? name : null;
}
