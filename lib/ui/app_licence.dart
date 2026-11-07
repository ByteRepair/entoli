import "package:flutter/foundation.dart";
import "package:flutter/services.dart" show rootBundle;

import "../data/licence_data.dart";
import "theme.dart" show appTitle;

/// Entoli's own licence, as the welcome tour shows it and the licence page
/// lists it.
final appLicence = LicenseEntryWithLineBreaks(const [appTitle], bundledLicence);

/// Puts [appLicence] on the licence page About opens, beside what the app is
/// built on.
void registerAppLicence() => LicenseRegistry.addLicense(() async* {
  yield appLicence;
});

/// blink's ISC licence, for the x86-64 emulator blinkish runs on. The notice
/// travels with the binary, so it is registered beside the app's own.
void registerBlinkLicence() => LicenseRegistry.addLicense(() async* {
  yield LicenseEntryWithLineBreaks(
    const ["blink"],
    await rootBundle.loadString("assets/third_party/blink-ISC.txt"),
  );
});
