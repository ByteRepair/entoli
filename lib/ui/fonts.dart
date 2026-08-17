import "package:flutter/foundation.dart";
import "package:flutter/services.dart" show rootBundle;

/// The face anything shown verbatim is set in: code, a tool's command and its
/// output, a chat id, a config value.
///
/// Bundled rather than the `monospace` alias, which resolves to whatever the
/// device has — Roboto Mono on one Android, Droid Sans Mono on another, DejaVu
/// on this desktop, per-browser on the web. Those things are shown verbatim
/// because their exact characters line up, which is a poor thing to leave to
/// the platform.
const monoFamily = "RobotoMono";

/// Roboto Mono is under the SIL Open Font Licence, which asks for the licence
/// to travel with the font. This puts it in front of a reader rather than only
/// in the repository — Flutter's own licence page reads the registry, so the
/// text ships whether or not the app has grown a page that shows it.
///
/// Read lazily: the registry takes a stream and drains it only when something
/// asks, so a run that never opens a licence page never opens the file.
void registerBundledFontLicences() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const [monoFamily],
      await rootBundle.loadString("assets/fonts/OFL.txt"),
    );
  });
}
