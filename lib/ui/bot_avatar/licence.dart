import "package:flutter/foundation.dart";
import "package:flutter/services.dart" show rootBundle;

import "../../data/bot_avatar_library.dart" show botAvatarLicenceAsset;

/// The Bot Avatar engine is a port of Open Bot Avatar and its presets are
/// that project's starters and gallery, all under the MIT licence, which
/// asks for its notice to travel with them. Read lazily, as the fonts' are.
void registerBotAvatarLicence() => LicenseRegistry.addLicense(() async* {
  yield LicenseEntryWithLineBreaks([
    "Open Bot Avatar",
  ], await rootBundle.loadString(botAvatarLicenceAsset));
});
