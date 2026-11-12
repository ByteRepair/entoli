import "package:flutter/widgets.dart";

import "../../app/pages/marketplace.dart";
import "../app_pages.dart";

/// Open the marketplace: the sidebar's tile and the app menu.
void openMarketplace(BuildContext context) =>
    openAppPage(context, MarketplaceAppPage());
