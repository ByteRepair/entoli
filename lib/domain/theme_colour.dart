/// The indigo the app's icon sits on, and the seed of the palette it has by
/// default. Here rather than beside `entoliIndigo`, which is this number as a
/// `Color`: a const one cannot be built from an enum's field, so one of the two
/// has to be the literal and the layer that has no `Color` is it.
const entoliIndigoArgb = 0xFF4F46E5;

/// Apple's systemBlue, the seed of the palette a fresh install has. A literal
/// beside the enum for the reason [entoliIndigoArgb] is: `entoliLook` is const.
const appleBlueArgb = 0xFF007AFF;

/// Which row a [ThemeColour] is drawn in, and how the palette is built from it.
enum ThemeColourGroup {
  /// Picked only through a [ColourTheme], never on its own.
  theme,
  bold,
  pastel;

  /// Whether the palette keeps the seed's own chroma. The pastels are strong
  /// colours that Material's default variant softens, which is what makes
  /// them pastel; the other two are meant to look like the swatch.
  bool get vivid => this != pastel;
}

/// A colour the palette is seeded from, offered for the primary and the
/// secondary alike. Declaration order within a group is the order the settings
/// page draws them in. [indigo], the app's own, is first among the pastels;
/// the default is the iOS / macOS theme, [apple] as both seeds.
///
/// Held as ARGB rather than as a `Color` for the reason `AppTheme` mirrors
/// `ThemeMode`: nothing in `domain/` takes a UI dependency. `ui/theme.dart`
/// maps one to the other.
///
/// The pastels keep their unprefixed names: those are what `settings.json`
/// has always stored.
enum ThemeColour {
  // Tailwind's 600 tone of each, which is what the indigo the icon sits on
  // already was — eight colours picked to look like one another rather than one
  // per family from wherever it happened to sit.
  indigo("Indigo", entoliIndigoArgb),
  violet("Violet", 0xFF7C3AED),
  blue("Blue", 0xFF2563EB),
  teal("Teal", 0xFF0D9488),
  green("Green", 0xFF16A34A),
  amber("Amber", 0xFFD97706),
  red("Red", 0xFFDC2626),
  pink("Pink", 0xFFDB2777),

  // Material's 500 tones. Yellow is its amber: a true yellow is unreadable as a
  // primary on a light surface.
  boldRed("Red", 0xFFF44336, group: ThemeColourGroup.bold),
  boldOrange("Orange", 0xFFFF9800, group: ThemeColourGroup.bold),
  boldYellow("Yellow", 0xFFFFC107, group: ThemeColourGroup.bold),
  boldGreen("Green", 0xFF4CAF50, group: ThemeColourGroup.bold),
  boldCyan("Cyan", 0xFF00BCD4, group: ThemeColourGroup.bold),
  boldBlue("Blue", 0xFF2196F3, group: ThemeColourGroup.bold),
  boldPurple("Purple", 0xFF9C27B0, group: ThemeColourGroup.bold),
  boldBrown("Brown", 0xFF795548, group: ThemeColourGroup.bold),
  boldSlate("Slate", 0xFF607D8B, group: ThemeColourGroup.bold),

  // As each upstream publishes it; see [ColourTheme].
  apple("iOS / macOS", appleBlueArgb,
      group: ThemeColourGroup.theme, greySurfaces: true),
  windows("Windows", 0xFF0078D7,
      group: ThemeColourGroup.theme, greySurfaces: true),
  adwaita("GNOME Adwaita", 0xFF3584E4,
      group: ThemeColourGroup.theme, greySurfaces: true),
  breeze("KDE Breeze", 0xFF3DAEE9,
      group: ThemeColourGroup.theme, greySurfaces: true),
  ubuntuOrange("Ubuntu orange", 0xFFE95420,
      group: ThemeColourGroup.theme, greySurfaces: true),
  ubuntuAubergine("Ubuntu aubergine", 0xFF77216F, group: ThemeColourGroup.theme),
  materialPrimary("Material primary", 0xFF6750A4, group: ThemeColourGroup.theme),
  materialSecondary("Material secondary", 0xFF625B71, group: ThemeColourGroup.theme),
  draculaPurple("Dracula purple", 0xFFBD93F9, group: ThemeColourGroup.theme),
  draculaPink("Dracula pink", 0xFFFF79C6, group: ThemeColourGroup.theme),
  nordFrost("Nord frost", 0xFF88C0D0, group: ThemeColourGroup.theme),
  nordBlue("Nord blue", 0xFF5E81AC, group: ThemeColourGroup.theme),
  solarizedBlue("Solarized blue", 0xFF268BD2, group: ThemeColourGroup.theme),
  solarizedYellow("Solarized yellow", 0xFFB58900, group: ThemeColourGroup.theme),
  gruvboxYellow("Gruvbox yellow", 0xFFD79921, group: ThemeColourGroup.theme),
  gruvboxAqua("Gruvbox aqua", 0xFF689D6A, group: ThemeColourGroup.theme);

  const ThemeColour(this.label, this.argb,
      {this.group = ThemeColourGroup.pastel, this.greySurfaces = false});

  final String label;
  final int argb;
  final ThemeColourGroup group;

  /// Whether, as the primary, the surfaces are neutral grey rather than tinted
  /// with it: the desktop and phone systems paint their windows grey, and
  /// Material tints them.
  final bool greySurfaces;

  static Iterable<ThemeColour> inGroup(ThemeColourGroup group) =>
      values.where((c) => c.group == group);
}

/// A well-known colour scheme, picked as one: it sets both seeds. A scheme
/// with a single accent has it as both.
///
/// Sources: Apple's systemBlue, Windows' default WindowColor, libadwaita's
/// default accent, Breeze's DecorationFocus, Ubuntu's brand orange and light
/// aubergine, Material 3's baseline primary40 and secondary40, Dracula's
/// purple and pink, Nord's nord8 and nord10, Solarized's blue and yellow,
/// Gruvbox's neutral yellow and aqua.
enum ColourTheme {
  apple(ThemeColour.apple, ThemeColour.apple),
  windows(ThemeColour.windows, ThemeColour.windows),
  adwaita(ThemeColour.adwaita, ThemeColour.adwaita),
  breeze(ThemeColour.breeze, ThemeColour.breeze),
  ubuntu(ThemeColour.ubuntuOrange, ThemeColour.ubuntuAubergine, "Ubuntu"),
  material(ThemeColour.materialPrimary, ThemeColour.materialSecondary,
      "Material You"),
  dracula(ThemeColour.draculaPurple, ThemeColour.draculaPink, "Dracula"),
  nord(ThemeColour.nordFrost, ThemeColour.nordBlue, "Nord"),
  solarized(ThemeColour.solarizedBlue, ThemeColour.solarizedYellow, "Solarized"),
  gruvbox(ThemeColour.gruvboxYellow, ThemeColour.gruvboxAqua, "Gruvbox");

  const ColourTheme(this.primary, this.secondary, [this._label]);

  final ThemeColour primary;
  final ThemeColour secondary;
  final String? _label;

  String get label => _label ?? primary.label;
}
