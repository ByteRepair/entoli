/// The pages a project has beside its chats, and whether it has each: the
/// buttons beside the sidebar's switcher and the app's Project menu. The
/// default project has no settings page, so its workspace and its memories; a
/// built-in the halves its spec says it has, plus a settings page where its
/// spec says it has one worth opening; a user's project its settings page. A
/// paired device's has no workspace here.
library;

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../domain/project.dart";
import "../providers.dart";

export "../app/projects.dart";
import "../app/pages/memory.dart";
import "../app/pages/project_settings.dart";
import "../app/pages/workspace.dart";
import "app_pages.dart";

void openProjectWorkspace(BuildContext context, WidgetRef ref, ProjectRef at) =>
    openAppPage(
      context,
      WorkspaceAppPage(
        root: ref
            .read(appConfigProvider)
            .projectWorkspaceDir(project: at.project),
        owner: "${projectLabel(at.project)} workspace",
      ),
    );

/// The app's own store: what the default project shows beside its workspace
/// in place of a settings page, and what a built-in with [MemoryPolicy.app]
/// shows for the same reason.
void openProjectMemories(BuildContext context, ProjectRef at) => openAppPage(
  context,
  MemoryAppPage(project: (device: at.device, project: null), owner: "Memories"),
);

void openProjectSettings(BuildContext context, ProjectRef at) => openAppPage(
  context,
  ProjectSettingsAppPage(at.project!, device: at.device),
);
