import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// Puts [text] on the clipboard.
func copyToPasteboard(_ text: String) {
  #if os(iOS)
    UIPasteboard.general.string = text
  #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  #endif
}

/// A search's words: what is found holds every one of them, in any order.
struct SearchWords {
  private let words: [String]

  init(_ query: String) {
    words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
  }

  var isEmpty: Bool { words.isEmpty }

  /// Whether [text], already lowercased, holds every word.
  func found(in text: String) -> Bool { words.allSatisfy(text.contains) }
}

extension Binding where Value == Bool {
  /// Whether [value] is set: what presents a sheet or alert over it, and
  /// clears it once that is dismissed.
  static func present<T>(_ value: Binding<T?>) -> Binding<Bool> {
    Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
  }
}
