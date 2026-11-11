import Foundation

/// Whether the app draws in the system's glass, read at launch before Dart
/// runs, so the window is the shell's from its first frame rather than taken
/// over once Dart has said so. It reads what Dart's `dataDir()` and
/// `AppSettings.liquidGlass` read, and must stay their copy: the directory is
/// `$ENTOLI_CONFIG`, else `~/.config/<leaf>` on macOS and `Documents/entoli`
/// on iOS; the switch is on unless `settings.json` says `false`.
enum LaunchSettings {
  static var liquidGlass: Bool {
    guard let dir = dataDir,
      let data = try? Data(contentsOf: dir.appendingPathComponent("settings.json")),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return true }
    return json["liquidGlass"] as? Bool ?? true
  }

  private static var dataDir: URL? {
    if let dir = ProcessInfo.processInfo.environment["ENTOLI_CONFIG"] {
      return URL(fileURLWithPath: dir)
    }
    #if os(macOS)
      guard let home = ProcessInfo.processInfo.environment["HOME"] else { return nil }
      // Dart's `kDebugMode` leaf: the Runner's xcconfigs set it per build
      // configuration, which this package's own flags do not follow.
      let leaf = Bundle.main.object(forInfoDictionaryKey: "EntoliDataLeaf") as? String
      return URL(fileURLWithPath: home)
        .appendingPathComponent(".config")
        .appendingPathComponent(leaf ?? "entoli")
    #else
      return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("entoli")
    #endif
  }
}
