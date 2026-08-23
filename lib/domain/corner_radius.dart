/// How round every corner the theme rounds is. Declaration order is the order
/// the settings page draws them in.
///
/// Named after Material's shape scale, which is where the numbers come from —
/// `medium` is the radius a card had before any of this was a setting.
enum CornerRadius {
  none(0),
  extraSmall(4),
  small(8),
  medium(12),
  large(16),
  largeIncreased(20),
  extraLarge(28),
  extraLargeIncreased(32);

  const CornerRadius(this.radius);

  final double radius;

  /// An unknown name is a file written by a later build, so it falls back
  /// rather than failing the whole settings load.
  static CornerRadius fromName(String? name) =>
      values.firstWhere((corner) => corner.name == name, orElse: () => medium);
}
