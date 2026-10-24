import "package:flutter/foundation.dart";

import "../data/licence_data.dart";
import "theme.dart" show appTitle;

/// Entoli's own licence, as the welcome tour shows it and the licence page
/// lists it.
final appLicence = LicenseEntryWithLineBreaks(const [appTitle], bundledLicence);

/// Puts [appLicence] on the licence page About opens, beside what the app is
/// built on.
void registerAppLicence() =>
    LicenseRegistry.addLicense(() async* {
      yield appLicence;
    });
