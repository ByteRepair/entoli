/// The indigo the app's icon sits on, and the seed of the palette it has by
/// default. Here rather than beside `entoliIndigo`, which is this number as a
/// `Color`: a const one cannot be built from an enum's field, so one of the two
/// has to be the literal and the layer that has no `Color` is it.
const entoliIndigoArgb = 0xFF4F46E5;

/// A colour the palette is seeded from, offered for the primary and the
/// secondary alike. Declaration order is the order the settings page draws
/// them in, and [indigo] — the app's own — is first because it is the default.
///
/// Held as ARGB rather than as a `Color` for the reason `AppTheme` mirrors
/// `ThemeMode`: nothing in `domain/` takes a UI dependency. `ui/theme.dart`
/// maps one to the other.
enum ThemeColour {
  indigo("Indigo", entoliIndigoArgb),
  violet("Violet", 0xFF7C3AED),
  blue("Blue", 0xFF2563EB),
  teal("Teal", 0xFF0D9488),
  green("Green", 0xFF16A34A),
  amber("Amber", 0xFFD97706),
  red("Red", 0xFFDC2626),
  pink("Pink", 0xFFDB2777);

  const ThemeColour(this.label, this.argb);

  final String label;

  /// Tailwind's 600 tone of each, which is what the indigo the icon sits on
  /// already was — eight colours picked to look like one another rather than
  /// one per family from wherever it happened to sit.
  final int argb;

  /// An unknown name is a file written by a later build, so it falls back
  /// rather than failing the whole settings load.
  static ThemeColour fromName(String? name) =>
      values.firstWhere((colour) => colour.name == name, orElse: () => indigo);
}
