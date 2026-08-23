/// The corner radii the settings page offers, in the order it draws them. One
/// number rounds every corner the app draws — see "The theme".
const cornerRadii = [0.0, 4.0, 8.0, 12.0, 16.0, 20.0, 24.0, 28.0];

/// Material's own card radius, and so the middle of the row.
const defaultCornerRadius = 12.0;

/// A radius this build does not offer is a file written by a later one, so it
/// falls back rather than theming the app to a corner no chip is selected for.
double cornerRadiusFrom(Object? value) {
  final radius = value is num ? value.toDouble() : null;
  return cornerRadii.contains(radius) ? radius! : defaultCornerRadius;
}
