/// The pages a project has beside its chats, and whether it has each: the
/// buttons beside the sidebar's switcher and the app's Project menu. The
/// default project has no settings page, so its workspace and its memories; a
/// built-in the halves its spec says it has, plus a settings page where its
/// spec says it has one worth opening; a user's project its settings page. A
/// paired device's has no workspace here.
library;

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/builtin_project.dart";
import "../domain/project.dart";
import "../providers.dart";
import "memory/memory_page.dart";
import "sidebar/project_settings_page.dart";
import "workspace/workspace_page.dart";

bool projectHasWorkspace(ProjectRef at) =>
    at.device == null &&
    (builtinProjectOf(at.project)?.sharedWorkspace ?? true);

bool projectHasMemories(ProjectRef at) =>
    builtinProjectOf(at.project)?.memory != MemoryPolicy.off;

bool projectHasSettings(ProjectRef at) =>
    at.project != null && projectHasSettingsPage(at.project);

void openProjectWorkspace(BuildContext context, WidgetRef ref, ProjectRef at) {
  final title = "${projectLabel(at.project)} workspace";
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => WorkspacePage(
        root: ref
            .read(appConfigProvider)
            .projectWorkspaceDir(project: at.project),
        title: title,
      ),
    ),
  );
}

/// The app's own store: what the default project shows beside its workspace
/// in place of a settings page, and what a built-in with [MemoryPolicy.app]
/// shows for the same reason.
void openProjectMemories(BuildContext context, ProjectRef at) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => MemoryPage(
        project: (device: at.device, project: null),
        title: "Memories",
      ),
    ),
  );
}

void openProjectSettings(BuildContext context, ProjectRef at) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          ProjectSettingsPage(project: at.project!, device: at.device),
    ),
  );
}
