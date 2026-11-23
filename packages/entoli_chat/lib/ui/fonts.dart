import "package:flutter/foundation.dart";
import "package:flutter/services.dart" show rootBundle;

/// The face anything shown verbatim is set in: code, a tool's command and its
/// output, a chat id, a config value.
///
/// Bundled rather than the `monospace` alias, which resolves to whatever the
/// device has — Roboto Mono on one Android, Droid Sans Mono on another, DejaVu
/// on this desktop. Those things are shown verbatim
/// because their exact characters line up, which is a poor thing to leave to
/// the platform.
const monoFamily = "$_fonts/RobotoMono";

/// A font a package declares is registered under its name, not the app's.
const _fonts = "packages/entoli_chat";

/// The two faces the artifact stylesheet names — Playfair Display headings
/// over a Source Serif 4 body — worn by the whole app through `entoliTheme`,
/// not only by its artifacts. Both are bundled rather than linked the way the
/// stylesheet does it, because a Flutter view has no Google Fonts `<link>`:
/// the engine reads only what pubspec declares, and what ships is subset
/// small.
const displayFamily = "$_fonts/PlayfairDisplay";

const bodyFamily = "$_fonts/SourceSerif4";

/// All three families are under the SIL Open Font Licence, which asks for the
/// licence to travel with the font. This puts them in front of a reader rather
/// than only in the repository — the licence page the About category opens
/// reads the registry, so the text is in front of whoever looks.
///
/// Read lazily: the registry takes a stream and drains it only when something
/// asks, so a run that never opens a licence page never opens the files.
void registerBundledFontLicences() {
  LicenseRegistry.addLicense(() async* {
    for (final (family, file) in const [
      ("RobotoMono", "$_fonts/assets/fonts/OFL.txt"),
      ("PlayfairDisplay", "$_fonts/assets/fonts/PlayfairDisplay-OFL.txt"),
      ("SourceSerif4", "$_fonts/assets/fonts/SourceSerif4-OFL.txt"),
    ]) {
      yield LicenseEntryWithLineBreaks([
        family,
      ], await rootBundle.loadString(file));
    }
  });
}
