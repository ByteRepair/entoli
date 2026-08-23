/// The colour the system is themed to — on Android, the accent Material You
/// took from the wallpaper. Read once at startup.
///
/// Null is a platform that has none: everything but Android, and an Android
/// older than 12, where the accent resources do not exist. That null is what
/// takes the Material 3 Expressive switch off the settings page, so nothing
/// else has to ask which version of which platform this is.
abstract interface class SystemPalette {
  Future<int?> accent();
}
