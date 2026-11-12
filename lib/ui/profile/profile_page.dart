import "package:flutter/widgets.dart";

import "../../app/pages/profile.dart";
import "../app_pages.dart";

/// Open the app-level profile: the sidebar's tile and the app menu.
void openProfile(BuildContext context) =>
    openAppPage(context, ProfileAppPage());
