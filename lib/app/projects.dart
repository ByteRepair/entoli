/// Which pages a project has beside its chats: the buttons beside the
/// sidebar's switcher and the app's Project menu, in either frontend. The
/// default project has no settings page, so its workspace and its memories;
/// a built-in the halves its spec says it has, plus a settings page where
/// its spec says it has one worth opening; a user's project its settings
/// page. A paired device's has no workspace here.
library;

import "../domain/builtin_project.dart";
import "../domain/project.dart";

bool projectHasWorkspace(ProjectRef at) =>
    at.device == null &&
    (builtinProjectOf(at.project)?.sharedWorkspace ?? true);

bool projectHasMemories(ProjectRef at) =>
    builtinProjectOf(at.project)?.memory != MemoryPolicy.off;

bool projectHasSettings(ProjectRef at) => projectHasSettingsPage(at.project);
