import SwiftUI

extension TranscriptIcon {
  /// Apple's symbol for what the icon means, one exhaustive switch so a
  /// glyph added to the contract compiles nowhere until it has one.
  var symbol: String {
    switch self {
    case .terminal: "terminal"
    case .thinking: "brain"
    case .file: "doc.text"
    case .edit: "pencil"
    case .search: "magnifyingglass"
    case .web: "globe"
    case .subAgent: "point.3.connected.trianglepath.dotted"
    case .question: "questionmark.circle"
    case .permissionGranted: "checkmark.shield"
    case .permissionDenied: "exclamationmark.shield"
    case .plan: "checklist"
    case .artifact: "chart.bar.doc.horizontal"
    case .skill: "puzzlepiece.extension"
    case .folderAdd: "folder.badge.plus"
    case .shield: "shield"
    case .error: "exclamationmark.circle"
    case .goalActive: "scope"
    case .goalPaused: "pause.circle"
    case .goalMet: "checkmark.circle"
    case .goalBlocked: "nosign"
    case .goalResumed: "play.circle"
    case .goalCleared: "xmark.circle"
    case .info: "info.circle"
    }
  }
}

/// Text put on the system's pasteboard.
enum Pasteboard {
  static func copy(_ text: String) {
    #if os(iOS)
      UIPasteboard.general.string = text
    #else
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #endif
  }
}
